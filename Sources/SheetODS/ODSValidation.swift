import Foundation
import SheetCore

/// Data validation in ODF (`table:content-validation`), both ways.
///
/// ODF keeps the rules in one `table:content-validations` list at the top of `office:spreadsheet` and has each cell
/// name the rule it obeys (`table:content-validation-name`); Excel keeps the rule and the cells it covers together.
/// The condition texts are OpenFormula predicates — `of:cell-content-is-whole-number() and cell-content-is-between(1,100)` —
/// and the spellings here are the ones LibreOffice writes and reads (Appendix B.16).
enum ODSValidation {
    /// `table:condition` for one rule.
    static func condition(_ v: DataValidation, sheet: String) -> String {
        let one = v.formula1.map { operand($0, sheet: sheet) } ?? ""
        let two = v.formula2.map { operand($0, sheet: sheet) } ?? ""
        switch v.kind {
        case .none: return ""
        case .custom: return "of:is-true-formula(\(one))"
        case .list:
            // an inline list is written `"a,b,c"` in XLSX and `("a";"b";"c")` in ODF
            if let raw = v.formula1, raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
                let items = String(raw.dropFirst().dropLast()).split(separator: ",", omittingEmptySubsequences: false)
                return "of:cell-content-is-in-list(" + items.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: ";") + ")"
            }
            return "of:cell-content-is-in-list(\(one))"
        case .textLength:
            if let op = v.operator, op == .between || op == .notBetween {
                return "of:cell-content-text-length-is-\(op == .between ? "between" : "not-between")(\(one),\(two))"
            }
            return "of:cell-content-text-length()\(comparison(v.operator))\(one)"
        case .whole, .decimal, .date, .time:
            let test = ["whole": "cell-content-is-whole-number", "decimal": "cell-content-is-decimal-number",
                        "date": "cell-content-is-date", "time": "cell-content-is-time"][v.kind.rawValue]!
            guard let op = v.operator, v.formula1 != nil else { return "of:\(test)()" }
            switch op {
            case .between: return "of:\(test)() and cell-content-is-between(\(one),\(two))"
            case .notBetween: return "of:\(test)() and cell-content-is-not-between(\(one),\(two))"
            default: return "of:\(test)() and cell-content()\(comparison(op))\(one)"
            }
        }
    }

    private static func comparison(_ op: DataValidation.Operator?) -> String {
        switch op {
        case .equal, nil: return "="
        case .notEqual: return "!="
        case .lessThan: return "<"
        case .lessThanOrEqual: return "<="
        case .greaterThan: return ">"
        case .greaterThanOrEqual: return ">="
        case .between, .notBetween: return "="
        }
    }

    /// An XLSX operand as ODF text. Sheet-qualified references keep their sheet.
    static func operand(_ text: String, sheet: String) -> String {
        let expr = FormulaExpr.parse(text, dialect: .xlsx)
        if expr.isUnparsed { return text }
        return String(expr.rendered(as: .ods).dropFirst(4))
    }

    /// The `table:content-validation` elements of a workbook, in the order the sheets have them.
    static func xml(_ wb: Workbook, names: inout [Int: [(ranges: MultiCellRange, name: String)]], sink: ODSWarningSink) -> String {
        var out = ""
        var n = 0
        for (i, sheet) in wb.sheets.enumerated() {
            for v in sheet.dataValidations {
                n += 1
                let name = "val\(n)"
                names[i, default: []].append((v.ranges, name))
                let anchor = v.ranges.sorted.first?.topLeft ?? CellRef(row: 0, col: 0)
                let base = "\(String(ODSWriter.odsSheetPrefix(sheet.name).dropFirst())).\(anchor.a1)"
                out += "<table:content-validation table:name=\"\(name)\""
                let condition = condition(v, sheet: sheet.name)
                if !condition.isEmpty { out += " table:condition=\"\(XML.esc(condition))\"" }
                out += " table:allow-empty-cell=\"\(v.allowBlank)\""
                if v.kind == .list { out += " table:display-list=\"\(v.hideDropDown ? "no" : "unsorted")\"" }
                out += " table:base-cell-address=\"\(XML.esc(base))\">"
                if v.showInputMessage, v.promptTitle != nil || v.prompt != nil {
                    out += "<table:help-message"
                    if let t = v.promptTitle { out += " table:title=\"\(XML.esc(t))\"" }
                    out += " table:display=\"true\">"
                    out += (v.prompt.map { ODSWriter.paragraphsXML($0).joined() } ?? "")
                    out += "</table:help-message>"
                }
                if v.showErrorMessage {
                    out += "<table:error-message"
                    if let style = v.errorStyle { out += " table:message-type=\"\(style.rawValue)\"" }
                    if let t = v.errorTitle { out += " table:title=\"\(XML.esc(t))\"" }
                    out += " table:display=\"true\">"
                    out += (v.error.map { ODSWriter.paragraphsXML($0).joined() } ?? "")
                    out += "</table:error-message>"
                }
                out += "</table:content-validation>"
                if v.imeMode != nil {
                    sink.add(.dropped, subject: .formatting, sheet: sheet.name, "the input-method mode of a data validation is dropped: ODF has no such setting")
                }
            }
        }
        return out.isEmpty ? "" : "<table:content-validations>\(out)</table:content-validations>"
    }

    // MARK: - ODF → model

    /// One `table:content-validation` as read from the file, before its cells are known.
    struct Parsed {
        var name: String
        var condition: String
        var allowEmpty: Bool
        var displayList: String?
        var baseAddress: String?
        var helpTitle: String?
        var help: String?
        var errorTitle: String?
        var error: String?
        var errorType: String?
        var showError = false
        var showHelp = false
    }

    /// Turns a parsed rule into a `DataValidation` over `ranges`.
    static func validation(_ p: Parsed, ranges: MultiCellRange) -> DataValidation {
        var text = p.condition.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("of:") { text = String(text.dropFirst(3)) }
        var kind = DataValidation.Kind.none
        var op: DataValidation.Operator?
        var f1: String?, f2: String?

        // `<test>() and <comparison>` — the leading test names the kind
        var comparison = text
        for (prefix, k) in [("cell-content-is-whole-number()", DataValidation.Kind.whole),
                            ("cell-content-is-decimal-number()", .decimal),
                            ("cell-content-is-date()", .date),
                            ("cell-content-is-time()", .time)] where text.hasPrefix(prefix) {
            kind = k
            comparison = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if comparison.hasPrefix("and ") { comparison = String(comparison.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
            break
        }
        if comparison.hasPrefix("cell-content-text-length") {
            kind = .textLength
            comparison = String(comparison.dropFirst("cell-content-text-length".count))
            if comparison.hasPrefix("-is-between("), let args = ODSCondition.call("between(" + comparison.dropFirst("-is-between(".count))?.1 {
                op = .between; f1 = args.first.map(excel); f2 = args.count > 1 ? excel(args[1]) : nil
                comparison = ""
            } else if comparison.hasPrefix("-is-not-between("), let args = ODSCondition.call("between(" + comparison.dropFirst("-is-not-between(".count))?.1 {
                op = .notBetween; f1 = args.first.map(excel); f2 = args.count > 1 ? excel(args[1]) : nil
                comparison = ""
            } else if comparison.hasPrefix("()") {
                comparison = String(comparison.dropFirst(2))
            }
        }
        if !comparison.isEmpty {
            if comparison.hasPrefix("is-true-formula("), let args = ODSCondition.call(comparison)?.1 {
                kind = .custom; f1 = args.first.map(excel)
            } else if comparison.hasPrefix("cell-content-is-in-list("), let args = ODSCondition.call(comparison)?.1 {
                kind = .list
                // a literal list comes back as XLSX's `"a,b,c"`; a reference stays a reference
                if args.count > 1 || (args.first?.trimmingCharacters(in: .whitespaces).hasPrefix("\"") ?? false) {
                    let items = args.flatMap { $0.split(separator: ";").map(String.init) }.map(ODSCondition.unquote)
                    f1 = "\"" + items.joined(separator: ",") + "\""
                } else {
                    f1 = args.first.map(excel)
                }
            } else if comparison.hasPrefix("cell-content-is-between("), let args = ODSCondition.call(comparison)?.1 {
                op = .between; f1 = args.first.map(excel); f2 = args.count > 1 ? excel(args[1]) : nil
            } else if comparison.hasPrefix("cell-content-is-not-between("), let args = ODSCondition.call(comparison)?.1 {
                op = .notBetween; f1 = args.first.map(excel); f2 = args.count > 1 ? excel(args[1]) : nil
            } else {
                var rest = comparison
                if rest.hasPrefix("cell-content()") { rest = String(rest.dropFirst("cell-content()".count)) }
                for (prefix, o) in [(">=", DataValidation.Operator.greaterThanOrEqual), ("<=", .lessThanOrEqual),
                                    ("!=", .notEqual), ("<>", .notEqual), (">", .greaterThan), ("<", .lessThan), ("=", .equal)]
                where rest.hasPrefix(prefix) {
                    op = o; f1 = excel(String(rest.dropFirst(prefix.count)))
                    break
                }
            }
        }
        var v = DataValidation(kind: kind, ranges: ranges, formula1: f1, formula2: f2, operator: op)
        v.allowBlank = p.allowEmpty
        v.hideDropDown = p.displayList == "no"
        v.showInputMessage = p.showHelp
        v.promptTitle = p.helpTitle
        v.prompt = p.help
        v.showErrorMessage = p.showError
        v.errorTitle = p.errorTitle
        v.error = p.error
        v.errorStyle = p.errorType.flatMap { DataValidation.ErrorStyle(rawValue: $0) }
        return v
    }

    private static func excel(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        let expr = FormulaExpr.parse(t, dialect: .ods)
        return expr.isUnparsed ? t : expr.rendered(as: .xlsx)
    }
}
