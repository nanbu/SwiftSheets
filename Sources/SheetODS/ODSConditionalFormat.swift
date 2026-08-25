import Foundation
import SheetCore

/// Conditional formats in ODF, both ways.
///
/// ODF 1.3 itself only has `style:map` — one condition per cell style, and nothing at all for colour scales, data
/// bars or icon sets. Everything richer lives in LibreOffice's `calcext:` extension namespace, which is what every
/// current application reads and writes. SwiftSheets **writes** `calcext:conditional-formats` only; it **reads**
/// both, falling back to `style:map` for a file that has no `calcext:` block at all (a producer older than the
/// extension). LibreOffice writes both forms of the same rules, so a sheet that produced any `calcext:` block
/// ignores its `style:map` copies rather than counting every rule twice.
///
/// The condition texts here are LibreOffice's own, taken from what it writes when it converts a workbook carrying
/// every rule kind (`docs/implementation-spec.html`, Appendix B.16).
enum ODSCondition {
    // MARK: - Model → ODF

    /// The `calcext:value` text of a rule, or nil when the rule needs an element of its own
    /// (`calcext:color-scale` / `data-bar` / `icon-set` / `date-is`).
    static func text(for rule: ConditionalFormattingRule, anchor: CellRef) -> String? {
        switch rule.kind {
        case .cellIs:
            guard let op = rule.operator else { return nil }
            let a = rule.formulas.first.map(operand) ?? ""
            let b = rule.formulas.count > 1 ? operand(rule.formulas[1]) : ""
            switch op {
            case .lessThan: return "<\(a)"
            case .lessThanOrEqual: return "<=\(a)"
            case .equal: return "=\(a)"
            case .notEqual: return "!=\(a)"
            case .greaterThanOrEqual: return ">=\(a)"
            case .greaterThan: return ">\(a)"
            case .between: return "between(\(a),\(b))"
            case .notBetween: return "not-between(\(a),\(b))"
            case .containsText: return "contains-text(\(quoted(rule.text ?? "")))"
            case .notContains: return "not-contains-text(\(quoted(rule.text ?? "")))"
            case .beginsWith: return "begins-with(\(quoted(rule.text ?? "")))"
            case .endsWith: return "ends-with(\(quoted(rule.text ?? "")))"
            }
        case .expression:
            guard let f = rule.formulas.first else { return nil }
            return "formula-is(\(operand(f)))"
        case .containsText: return "contains-text(\(quoted(rule.text ?? "")))"
        case .notContainsText: return "not-contains-text(\(quoted(rule.text ?? "")))"
        case .beginsWith: return "begins-with(\(quoted(rule.text ?? "")))"
        case .endsWith: return "ends-with(\(quoted(rule.text ?? "")))"
        case .top10:
            let n = rule.rank ?? 10
            return "\(rule.bottom ? "bottom" : "top")-\(rule.percent ? "percent" : "elements")(\(n))"
        case .aboveAverage:
            let side = rule.aboveAverage ? "above" : "below"
            return rule.equalAverage ? "\(side)-equal-average" : "\(side)-average"
        case .uniqueValues: return "unique"
        case .duplicateValues: return "duplicate"
        case .containsErrors: return "is-error"
        case .notContainsErrors: return "is-no-error"
        // ODF has no blank condition; LibreOffice writes the formula it would evaluate, and reads it back as such.
        case .containsBlanks: return "formula-is(LEN(TRIM([.\(anchor.a1)]))=0)"
        case .notContainsBlanks: return "formula-is(LEN(TRIM([.\(anchor.a1)]))>0)"
        case .colorScale, .dataBar, .iconSet, .timePeriod: return nil
        }
    }

    /// `<calcext:date-is calcext:date>` for an XLSX `timePeriod`; nil when the period has no ODF spelling.
    static func dateIs(_ period: String) -> String? { periodToODF[period] }
    static func timePeriod(_ dateIs: String) -> String? { periodToODF.first { $0.value == dateIs }?.key }

    private static let periodToODF: [String: String] = [
        "today": "today", "yesterday": "yesterday", "tomorrow": "tomorrow",
        "last7Days": "last-7-days", "thisWeek": "this-week", "lastWeek": "last-week", "nextWeek": "next-week",
        "thisMonth": "this-month", "lastMonth": "last-month", "nextMonth": "next-month",
    ]

    /// `ConditionalValue.Kind` ⇄ `calcext:type`.
    static func valueType(_ kind: ConditionalValue.Kind) -> String {
        switch kind {
        case .min: return "minimum"
        case .max: return "maximum"
        case .num: return "number"
        case .percent: return "percent"
        case .percentile: return "percentile"
        case .formula: return "formula"
        }
    }
    static func valueKind(_ type: String) -> ConditionalValue.Kind {
        switch type {
        case "minimum", "auto-minimum": return .min
        case "maximum", "auto-maximum": return .max
        case "percent": return .percent
        case "percentile": return .percentile
        case "formula": return .formula
        default: return .num
        }
    }

    /// An operand written as XLSX formula text, in ODF's own spelling (`$B$1` → `[.$B$1]`). Plain numbers and
    /// quoted strings come through unchanged.
    static func operand(_ text: String) -> String {
        let expr = FormulaExpr.parse(text, dialect: .xlsx)
        if expr.isUnparsed { return text }
        return String(expr.rendered(as: .ods).dropFirst(4))
    }

    /// The inverse: ODF operand text as XLSX formula text.
    static func excelOperand(_ text: String) -> String {
        let expr = FormulaExpr.parse(text, dialect: .ods)
        return expr.isUnparsed ? text : expr.rendered(as: .xlsx)
    }

    static func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    // MARK: - ODF → model

    /// Reads a `calcext:value` (or a `style:map` condition, whose `cell-content()` / `is-true-formula` spellings are
    /// accepted too) back into a rule. `style` is what the named style it applies resolved to.
    static func rule(from raw: String, style: DifferentialStyle?, priority: Int, anchor: String = "A1") -> ConditionalFormattingRule? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        // the `style:map` spellings reduce to the `calcext:` ones
        if text.hasPrefix("cell-content-is-between(") { text = "between(" + text.dropFirst("cell-content-is-between(".count) }
        else if text.hasPrefix("cell-content-is-not-between(") { text = "not-between(" + text.dropFirst("cell-content-is-not-between(".count) }
        else if text.hasPrefix("is-true-formula(") { text = "formula-is(" + text.dropFirst("is-true-formula(".count) }
        else if text.hasPrefix("cell-content()") { text = String(text.dropFirst("cell-content()".count)) }

        func rule(_ kind: ConditionalFormattingRule.Kind) -> ConditionalFormattingRule {
            ConditionalFormattingRule(kind: kind, priority: priority, style: style)
        }
        func comparison(_ op: ConditionalFormattingRule.Operator, _ rest: Substring) -> ConditionalFormattingRule {
            var r = rule(.cellIs); r.operator = op; r.formulas = [excelOperand(String(rest))]
            return r
        }
        switch text {
        case "unique": return rule(.uniqueValues)
        case "duplicate": return rule(.duplicateValues)
        case "is-error": return rule(.containsErrors)
        case "is-no-error": return rule(.notContainsErrors)
        case "above-average", "below-average", "above-equal-average", "below-equal-average":
            var r = rule(.aboveAverage)
            r.aboveAverage = text.hasPrefix("above")
            r.equalAverage = text.contains("equal")
            return r
        default: break
        }
        if let (name, args) = call(text) {
            switch name {
            case "between", "not-between":
                guard args.count == 2 else { return nil }
                var r = rule(.cellIs)
                r.operator = name == "between" ? .between : .notBetween
                r.formulas = args.map(excelOperand)
                return r
            case "formula-is":
                guard let f = args.first else { return nil }
                // LibreOffice's spelling of the two blank rules, which ODF has no condition for
                if let blank = blankRule(f, style: style, priority: priority) { return blank }
                var r = rule(.expression); r.formulas = [excelOperand(f)]
                return r
            case "contains-text", "not-contains-text", "begins-with", "ends-with":
                guard let literal = args.first.map(unquote) else { return nil }
                let kind: ConditionalFormattingRule.Kind = name == "contains-text" ? .containsText
                    : name == "not-contains-text" ? .notContainsText
                    : name == "begins-with" ? .beginsWith : .endsWith
                var r = rule(kind)
                r.text = literal
                r.operator = kind == .containsText ? .containsText : kind == .notContainsText ? .notContains
                    : kind == .beginsWith ? .beginsWith : .endsWith
                r.anchorTextFormula(at: anchor)
                return r
            case "top-elements", "top-percent", "bottom-elements", "bottom-percent":
                var r = rule(.top10)
                r.rank = args.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 10
                r.bottom = name.hasPrefix("bottom")
                r.percent = name.hasSuffix("percent")
                return r
            default: return nil
            }
        }
        // a bare comparison: >5, <=3, !=0 …
        for (prefix, op) in [(">=", ConditionalFormattingRule.Operator.greaterThanOrEqual), ("<=", .lessThanOrEqual),
                             ("!=", .notEqual), ("<>", .notEqual), (">", .greaterThan), ("<", .lessThan), ("=", .equal)]
        where text.hasPrefix(prefix) {
            return comparison(op, text.dropFirst(prefix.count))
        }
        return nil
    }

    /// `LEN(TRIM([.D1]))=0` and its `>0` twin — LibreOffice's stand-in for Excel's blank rules.
    private static func blankRule(_ formula: String, style: DifferentialStyle?, priority: Int) -> ConditionalFormattingRule? {
        let squeezed = formula.filter { !$0.isWhitespace }.uppercased()
        guard squeezed.hasPrefix("LEN(TRIM(") else { return nil }
        if squeezed.hasSuffix("))=0") { return ConditionalFormattingRule(kind: .containsBlanks, priority: priority, style: style) }
        if squeezed.hasSuffix("))>0") { return ConditionalFormattingRule(kind: .notContainsBlanks, priority: priority, style: style) }
        return nil
    }

    /// `name(arg,arg)` split at the top level; nil when the text is not a call.
    static func call(_ text: String) -> (String, [String])? {
        guard let open = text.firstIndex(of: "("), text.hasSuffix(")") else { return nil }
        let name = String(text[text.startIndex..<open])
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0 == "-" }) else { return nil }
        let body = text[text.index(after: open)..<text.index(before: text.endIndex)]
        var args: [String] = []
        var current = ""
        var depth = 0, inString = false
        for ch in body {
            if inString {
                current.append(ch)
                if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true; current.append(ch)
            case "(", "[": depth += 1; current.append(ch)
            case ")", "]": depth -= 1; current.append(ch)
            case "," where depth == 0: args.append(current); current = ""
            default: current.append(ch)
            }
        }
        if !current.isEmpty || !args.isEmpty { args.append(current) }
        return (name, args)
    }

    static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 else { return t }
        return String(t.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
    }
}

/// Writes `calcext:conditional-formats` — the last child of a `table:table`.
enum ODSConditionalFormatWriter {
    /// `Sheet.A1:Sheet.C9 Sheet.E1:Sheet.E9` — every rectangle of the rule's `sqref`.
    static func address(_ ranges: MultiCellRange, sheet: String) -> String {
        let prefix = String(ODSWriter.odsSheetPrefix(sheet).dropFirst())
        return ranges.sorted.map { "\(prefix).\($0.topLeft.a1):\(prefix).\($0.bottomRight.a1)" }.joined(separator: " ")
    }

    static func xml(_ sheet: Sheet, styles: ODSConditionalStyleRegistry, sink: ODSWarningSink) -> String {
        guard !sheet.conditionalFormatting.isEmpty else { return "" }
        var out = ""
        // ODF has no priority attribute: document order is the order the rules are tried in, so the blocks are
        // written lowest priority first and the rules inside each block likewise.
        let blocks = sheet.conditionalFormatting.sorted {
            ($0.rules.map(\.priority).min() ?? 0, $0.ranges.description) < ($1.rules.map(\.priority).min() ?? 0, $1.ranges.description)
        }
        for block in blocks {
            let target = address(block.ranges, sheet: sheet.name)
            let anchor = block.ranges.sorted.first?.topLeft ?? CellRef(row: 0, col: 0)
            let base = "\(String(ODSWriter.odsSheetPrefix(sheet.name).dropFirst())).\(anchor.a1)"
            var conditions = ""
            var standalone = ""
            for rule in block.rules.sorted(by: { $0.priority < $1.priority }) {
                switch rule.kind {
                case .colorScale:
                    guard let scale = rule.colorScale else { break }
                    standalone += "<calcext:conditional-format calcext:target-range-address=\"\(XML.esc(target))\"><calcext:color-scale>"
                    for (i, v) in scale.values.enumerated() {
                        var nonRGB = false
                        let colour = i < scale.colors.count ? ODSColor.hex(scale.colors[i], nonRGB: &nonRGB) : "#ffffff"
                        standalone += "<calcext:color-scale-entry calcext:value=\"\(XML.esc(v.value ?? "0"))\" calcext:type=\"\(ODSCondition.valueType(v.kind))\" calcext:color=\"\(colour)\"/>"
                    }
                    standalone += "</calcext:color-scale></calcext:conditional-format>"
                case .dataBar:
                    guard let bar = rule.dataBar else { break }
                    var nonRGB = false
                    let colour = ODSColor.hex(bar.color, nonRGB: &nonRGB)
                    standalone += "<calcext:conditional-format calcext:target-range-address=\"\(XML.esc(target))\">"
                    standalone += "<calcext:data-bar"
                    if let v = bar.minLength { standalone += " calcext:min-length=\"\(v)\"" }
                    if let v = bar.maxLength { standalone += " calcext:max-length=\"\(v)\"" }
                    standalone += " calcext:positive-color=\"\(colour)\" calcext:negative-color=\"#ff0000\" calcext:axis-position=\"none\" calcext:axis-color=\"#000000\">"
                    for v in [bar.minimum, bar.maximum] {
                        standalone += "<calcext:formatting-entry calcext:value=\"\(XML.esc(v.value ?? "0"))\" calcext:type=\"\(ODSCondition.valueType(v.kind))\"/>"
                    }
                    standalone += "</calcext:data-bar></calcext:conditional-format>"
                    if !bar.showValue {
                        sink.add(.degraded, subject: .formatting, sheet: sheet.name, "data bar written with its number showing: ODF has no way to hide it")
                    }
                case .iconSet:
                    guard let icons = rule.iconSet else { break }
                    standalone += "<calcext:conditional-format calcext:target-range-address=\"\(XML.esc(target))\">"
                    standalone += "<calcext:icon-set calcext:icon-set-type=\"\(XML.esc(icons.name))\">"
                    for v in icons.values {
                        standalone += "<calcext:formatting-entry calcext:value=\"\(XML.esc(v.value ?? "0"))\" calcext:type=\"\(ODSCondition.valueType(v.kind))\"/>"
                    }
                    standalone += "</calcext:icon-set></calcext:conditional-format>"
                    if !icons.showValue {
                        sink.add(.degraded, subject: .formatting, sheet: sheet.name, "icon set written with its number showing: ODF has no way to hide it")
                    }
                case .timePeriod:
                    guard let period = rule.timePeriod, let odf = ODSCondition.dateIs(period) else {
                        sink.add(.dropped, subject: .formatting, sheet: sheet.name, "date rule \"\(rule.timePeriod ?? "?")\" dropped: ODF has no such period")
                        break
                    }
                    let name = rule.style.flatMap { styles.name(for: $0) }
                    conditions += "<calcext:date-is calcext:date=\"\(odf)\"\(name.map { " calcext:style=\"\($0)\"" } ?? "")/>"
                default:
                    guard let value = ODSCondition.text(for: rule, anchor: anchor) else {
                        sink.add(.dropped, subject: .formatting, sheet: sheet.name, "conditional rule \(rule.kind.rawValue) dropped: ODF has no equivalent condition")
                        break
                    }
                    let name = rule.style.flatMap { styles.name(for: $0) }
                    conditions += "<calcext:condition calcext:value=\"\(XML.esc(value))\""
                    conditions += "\(name.map { " calcext:apply-style-name=\"\($0)\"" } ?? "")"
                    conditions += " calcext:base-cell-address=\"\(XML.esc(base))\"/>"
                }
            }
            if !conditions.isEmpty {
                out += "<calcext:conditional-format calcext:target-range-address=\"\(XML.esc(target))\">\(conditions)</calcext:conditional-format>"
            }
            out += standalone
        }
        return out.isEmpty ? "" : "<calcext:conditional-formats>\(out)</calcext:conditional-formats>"
    }
}

/// The named cell styles a conditional format paints with (`ConditionalStyle1`, `ConditionalStyle2`, …).
///
/// They are *named* styles, not automatic ones: `calcext:apply-style-name` and `style:map style:apply-style-name`
/// both name a style of `office:styles`, which lives in styles.xml. The names deliberately carry no underscore —
/// ODF encodes `_` in a style name as `_5f_`, and the two attributes disagree about which spelling they use.
final class ODSConditionalStyleRegistry {
    private var byStyle: [DifferentialStyle: String] = [:]
    private(set) var order: [(name: String, style: DifferentialStyle)] = []
    /// Font names the conditional styles ask for, so `office:font-face-decls` can declare them.
    private(set) var fonts: [String] = []
    /// Number formats that had to be dropped: an ODF conditional style names a data style, which SwiftSheets does
    /// not generate for conditional formats (it would have to live in styles.xml with its own name).
    private(set) var droppedNumberFormats: [String] = []
    private(set) var nonRGBColour = false

    var isEmpty: Bool { order.isEmpty }

    func name(for style: DifferentialStyle) -> String? {
        guard !style.isEmpty else { return nil }
        if let n = byStyle[style] { return n }
        let n = "ConditionalStyle\(order.count + 1)"
        byStyle[style] = n
        order.append((n, style))
        if let f = style.font?.name, !fonts.contains(f) { fonts.append(f) }
        if let code = style.numberFormat, code != NumberFormat.general, !droppedNumberFormats.contains(code) {
            droppedNumberFormats.append(code)
        }
        return n
    }

    /// The `style:style` elements, for `office:styles` of styles.xml.
    func xml() -> String {
        var out = ""
        for entry in order {
            let st = entry.style
            out += "<style:style style:name=\"\(entry.name)\" style:family=\"table-cell\" style:parent-style-name=\"Default\">"
            var cell = ""
            // an ODF cell style has one background colour, so a gradient contributes its first stop
            if let fill = st.fill, fill.patternType != .none || fill.gradientFill != nil,
               let fg = fill.foregroundColor ?? fill.backgroundColor {
                var nonRGB = false
                let hex = ODSColor.hex(fg, nonRGB: &nonRGB)
                if nonRGB { nonRGBColour = true } else { cell += " fo:background-color=\"\(hex)\"" }
            }
            if let b = st.border {
                var nonRGB = false
                if b.left == b.right, b.left == b.top, b.left == b.bottom, let v = ODSBorder.value(b.left, nonRGB: &nonRGB) {
                    cell += " fo:border=\"\(v)\""
                } else {
                    if let v = ODSBorder.value(b.left, nonRGB: &nonRGB) { cell += " fo:border-left=\"\(v)\"" }
                    if let v = ODSBorder.value(b.right, nonRGB: &nonRGB) { cell += " fo:border-right=\"\(v)\"" }
                    if let v = ODSBorder.value(b.top, nonRGB: &nonRGB) { cell += " fo:border-top=\"\(v)\"" }
                    if let v = ODSBorder.value(b.bottom, nonRGB: &nonRGB) { cell += " fo:border-bottom=\"\(v)\"" }
                }
                if nonRGB { nonRGBColour = true }
            }
            if let a = st.alignment {
                if let v = a.vertical {
                    switch v {
                    case .top: cell += " style:vertical-align=\"top\""
                    case .center, .justify, .distributed: cell += " style:vertical-align=\"middle\""
                    case .bottom: cell += " style:vertical-align=\"bottom\""
                    }
                }
                if a.wrapText { cell += " fo:wrap-option=\"wrap\"" }
            }
            if let p = st.protection, !p.locked || p.hidden {
                cell += " style:cell-protect=\"\(p.locked ? (p.hidden ? "hidden-and-protected" : "protected") : (p.hidden ? "formula-hidden" : "none"))\""
            }
            if !cell.isEmpty { out += "<style:table-cell-properties\(cell)/>" }
            if let a = st.alignment, let h = a.horizontal {
                let v: String?
                switch h {
                case .left: v = "start"
                case .center, .centerContinuous: v = "center"
                case .right: v = "end"
                case .justify, .distributed: v = "justify"
                case .general, .fill: v = nil
                }
                if let v { out += "<style:paragraph-properties fo:text-align=\"\(v)\"/>" }
            }
            var text = ""
            if let f = st.font {
                if let n = f.name {
                    text += " style:font-name=\"\(XML.esc(n))\" style:font-name-asian=\"\(XML.esc(n))\" style:font-name-complex=\"\(XML.esc(n))\""
                }
                if let size = f.size {
                    let pt = ODSLength.pt(size)
                    text += " fo:font-size=\"\(pt)\" style:font-size-asian=\"\(pt)\" style:font-size-complex=\"\(pt)\""
                }
                if let bold = f.bold {
                    let w = bold ? "bold" : "normal"
                    text += " fo:font-weight=\"\(w)\" style:font-weight-asian=\"\(w)\" style:font-weight-complex=\"\(w)\""
                }
                if let italic = f.italic {
                    let v = italic ? "italic" : "normal"
                    text += " fo:font-style=\"\(v)\" style:font-style-asian=\"\(v)\" style:font-style-complex=\"\(v)\""
                }
                switch f.color {
                case .rgb(let v)?: text += " fo:color=\"#\(Units.shortColor(v).lowercased())\""
                case nil, .auto?: break
                default: nonRGBColour = true
                }
                if let u = f.underline {
                    text += " style:text-underline-style=\"solid\" style:text-underline-width=\"auto\" style:text-underline-color=\"font-color\""
                    if u == .double || u == .doubleAccounting { text += " style:text-underline-type=\"double\"" }
                }
                if let s = f.strikethrough {
                    text += s ? " style:text-line-through-style=\"solid\" style:text-line-through-type=\"single\""
                              : " style:text-line-through-style=\"none\""
                }
            }
            if !text.isEmpty { out += "<style:text-properties\(text)/>" }
            out += "</style:style>"
        }
        return out
    }
}
