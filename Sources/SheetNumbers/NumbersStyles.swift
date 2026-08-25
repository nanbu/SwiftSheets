import Foundation
import SheetCore

/// Cell formatting in a Numbers document, both ways.
///
/// A cell names two entries of its table's style list: a `TST.CellStyleArchive` (fill, borders, vertical alignment,
/// wrapping) and a `TSWP.ParagraphStyleArchive` (font, colour, horizontal alignment). Either may be absent, in which
/// case the table's own default for that region applies — `body_text_style`, `header_row_text_style` and friends.
/// Every archive is a *variation*: it states only what it overrides and inherits the rest from its parent, so a
/// property is looked up along the parent chain (`TSS.StyleArchive.parent`).
///
/// Number formats are separate again: the cell record names an entry of the format list per kind (number, currency,
/// date, duration, text, boolean), and each entry is a `TSK.FormatStructArchive` — a *description* of a format
/// (kind + decimal places + separator + …), not a format string. `NumbersFormat` turns that description into the
/// Excel code the model carries, and back.
struct NumbersStyleResolver {
    let doc: NumbersDocument
    /// style-list key → the style archive's object id.
    private var styles: [Int: Int] = [:]
    /// format-list key → the `TSK.FormatStructArchive` it holds.
    private var formats: [Int: ProtoMessage] = [:]
    private var headerRows = 0, headerColumns = 0, footerRows = 0, rowCount = 0
    private var bodyText: Int?, headerRowText: Int?, headerColumnText: Int?, footerRowText: Int?
    private var bodyCell: Int?, headerRowCell: Int?, headerColumnCell: Int?, footerRowCell: Int?
    private var resolved: [Int: CellStyle] = [:]

    init(doc: NumbersDocument, model: ProtoMessage, store: ProtoMessage) {
        self.doc = doc
        for entry in store.reference("styleTable").flatMap({ doc.object($0) })?.messages("entries") ?? [] {
            if let key = entry.int("key"), let ref = entry.reference("reference") { styles[key] = ref }
        }
        // BNC documents keep the formats in `format_table`; older ones in `format_table_pre_bnc`
        for id in [store.reference("format_table"), store.reference("format_table_pre_bnc")].compactMap({ $0 }) {
            for entry in doc.object(id)?.messages("entries") ?? [] {
                guard let key = entry.int("key"), let f = entry.message("format") else { continue }
                if formats[key] == nil { formats[key] = f }
            }
        }
        headerRows = model.int("number_of_header_rows") ?? 0
        headerColumns = model.int("number_of_header_columns") ?? 0
        footerRows = model.int("number_of_footer_rows") ?? 0
        rowCount = model.int("number_of_rows") ?? 0
        bodyText = model.reference("body_text_style")
        headerRowText = model.reference("header_row_text_style")
        headerColumnText = model.reference("header_column_text_style")
        footerRowText = model.reference("footer_row_text_style")
        bodyCell = model.reference("body_cell_style")
        headerRowCell = model.reference("header_row_style")
        headerColumnCell = model.reference("header_column_style")
        footerRowCell = model.reference("footer_row_style")
    }

    var isEmpty: Bool { styles.isEmpty && formats.isEmpty }

    /// The style of one cell. `nil` ids fall back to the table's default for the region the cell sits in.
    mutating func style(_ s: CellStorage, row: Int, col: Int) -> CellStyle {
        let textID = s.textStyleID.flatMap { styles[$0] } ?? defaultTextStyle(row: row, col: col)
        let cellID = s.cellStyleID.flatMap { styles[$0] } ?? defaultCellStyle(row: row, col: col)
        let formatKey = s.numFormatID ?? s.currencyFormatID ?? s.dateFormatID ?? s.durationFormatID ?? s.textFormatID ?? s.boolFormatID
        let cacheKey = (textID ?? 0) &* 1_000_003 &+ (cellID ?? 0) &* 1009 &+ (formatKey ?? -1)
        if let hit = resolved[cacheKey] { return hit }

        var style = CellStyle.default
        if let textID { apply(text: textID, to: &style) }
        if let cellID { apply(cell: cellID, to: &style) }
        if let key = formatKey, let format = formats[key], let code = NumbersFormat.excelCode(format, currency: s.currencyFormatID != nil) {
            style.numberFormat = code
        }
        resolved[cacheKey] = style
        return style
    }

    private func defaultTextStyle(row: Int, col: Int) -> Int? {
        if row < headerRows { return headerRowText }
        if col < headerColumns { return headerColumnText }
        if footerRows > 0, row >= rowCount - footerRows { return footerRowText }
        return bodyText
    }
    private func defaultCellStyle(row: Int, col: Int) -> Int? {
        if row < headerRows { return headerRowCell }
        if col < headerColumns { return headerColumnCell }
        if footerRows > 0, row >= rowCount - footerRows { return footerRowCell }
        return bodyCell
    }

    /// The properties message of a style that actually states `name`, found along the parent chain — a style
    /// archive is a variation and states only what it overrides.
    private func properties(_ id: Int, _ group: String, _ name: String) -> ProtoMessage? {
        var cursor: Int? = id
        var seen = Set<Int>()
        while let current = cursor, seen.insert(current).inserted, let object = doc.object(current) {
            if let p = object.message(group), p.has(name) { return p }
            cursor = object.message("super")?.reference("parent")
        }
        return nil
    }
    private func bool(_ id: Int, _ group: String, _ name: String) -> Bool? { properties(id, group, name)?.bool(name) }
    private func int(_ id: Int, _ group: String, _ name: String) -> Int? { properties(id, group, name)?.int(name) }
    private func float(_ id: Int, _ group: String, _ name: String) -> Double? { properties(id, group, name)?.float(name).map(Double.init) }
    private func string(_ id: Int, _ group: String, _ name: String) -> String? { properties(id, group, name)?.string(name) }
    private func message(_ id: Int, _ group: String, _ name: String) -> ProtoMessage? { properties(id, group, name)?.message(name) }

    private func apply(text id: Int, to style: inout CellStyle) {
        if let v = bool(id, "char_properties", "bold") { style.font.bold = v }
        if let v = bool(id, "char_properties", "italic") { style.font.italic = v }
        if let v = float(id, "char_properties", "font_size") { style.font.size = (v * 100).rounded() / 100 }
        if let v = string(id, "char_properties", "font_name") { style.font.name = NumbersStyleResolver.familyName(v); style.font.scheme = nil }
        if let c = message(id, "char_properties", "font_color").flatMap(NumbersStyleResolver.color) { style.font.color = c }
        if let u = int(id, "char_properties", "underline"), u != 0 { style.font.underline = u == 2 ? .double : .single }
        if let s = int(id, "char_properties", "strikethru") { style.font.strikethrough = s != 0 }
        switch int(id, "para_properties", "alignment") {
        case 0: style.alignment.horizontal = .left
        case 1: style.alignment.horizontal = .right
        case 2: style.alignment.horizontal = .center
        case 3: style.alignment.horizontal = .justify
        default: break                                    // 4 is "auto", which is Excel's General
        }
    }

    private func apply(cell id: Int, to style: inout CellStyle) {
        if let fill = message(id, "cell_properties", "cell_fill") {
            if let c = fill.message("color").flatMap(NumbersStyleResolver.color) { style.fill = .solid(c) }
            else if let gradient = fill.message("gradient") {
                let stops = gradient.messages("stops").enumerated().compactMap { i, s -> GradientFill.Stop? in
                    guard let c = s.message("color").flatMap(NumbersStyleResolver.color) else { return nil }
                    return GradientFill.Stop(Double(s.float("fraction") ?? Float(i)), c)
                }
                if !stops.isEmpty { style.fill = .gradient(GradientFill(kind: .linear, stops: stops)) }
            }
        }
        if let v = bool(id, "cell_properties", "text_wrap") { style.alignment.wrapText = v }
        switch int(id, "cell_properties", "vertical_alignment") {
        case 0: style.alignment.vertical = .top
        case 1: style.alignment.vertical = .center
        case 2: style.alignment.vertical = .bottom
        default: break
        }
        for (name, side) in [("top_stroke", \CellStyle.border.top), ("bottom_stroke", \CellStyle.border.bottom),
                             ("left_stroke", \CellStyle.border.left), ("right_stroke", \CellStyle.border.right)] {
            guard let stroke = message(id, "cell_properties", name), let s = NumbersStyleResolver.side(stroke) else { continue }
            style[keyPath: side] = s
        }
    }

    /// `TSP.Color` → the model's colour. Numbers keeps components as 0…1 floats.
    static func color(_ m: ProtoMessage) -> Color? {
        guard let r = m.float("r"), let g = m.float("g"), let b = m.float("b") else { return nil }
        func byte(_ v: Float) -> Int { Swift.max(0, Swift.min(255, Int((v * 255).rounded()))) }
        let a = m.float("a") ?? 1
        return Color(hex: String(format: "%02X%02X%02X%02X", byte(a), byte(r), byte(g), byte(b)))
    }

    /// `TSD.StrokeArchive` → a border side. A zero-width stroke is "no border".
    static func side(_ m: ProtoMessage) -> Side? {
        let width = Double(m.float("width") ?? 0)
        guard width > 0 else { return nil }
        let colour = m.message("color").flatMap(color)
        let style: Side.Style = width <= 0.3 ? .hair : width < 1.2 ? .thin : width < 2.2 ? .medium : .thick
        return Side(style: style, color: colour)
    }

    /// Numbers stores the PostScript font name ("HelveticaNeue-Bold"); the model wants the family ("Helvetica Neue").
    static func familyName(_ postScript: String) -> String {
        let stem = postScript.split(separator: "-").first.map(String.init) ?? postScript
        var out = ""
        for (i, ch) in stem.enumerated() {
            if i > 0, ch.isUppercase, !out.hasSuffix(" ") { out.append(" ") }
            out.append(ch)
        }
        return out
    }
}

/// `TSK.FormatStructArchive` ⇄ an Excel number-format code.
///
/// Numbers describes a format rather than spelling it: a kind (the `FormatType` constants numbers-parser recovered),
/// how many decimal places, whether to group thousands, a currency code, a date pattern. The everyday kinds map
/// exactly; the ones Excel has no word for (rating, checkbox, base-n) come back as General and the codec says so.
enum NumbersFormat {
    static func type(_ name: String) -> Int? { NumbersSchema.shared.constant("FormatType", name) }
    /// Numbers' "decide for yourself" decimal count.
    static let automaticDecimals = 253

    static func excelCode(_ f: ProtoMessage, currency: Bool) -> String? {
        guard let kind = f.int("format_type") else { return nil }
        let places = f.int("decimal_places") ?? 0
        let grouping = f.bool("show_thousands_separator") ?? false
        func decimals(_ n: Int, integer: String = "0") -> String {
            let head = grouping ? "#,##0" : integer
            return n > 0 && n != automaticDecimals ? head + "." + String(repeating: "0", count: n) : head
        }
        switch kind {
        case type("DECIMAL"): return decimals(places)
        case type("PERCENT"): return decimals(places) + "%"
        case type("SCIENTIFIC"): return "0." + String(repeating: "0", count: Swift.max(2, places == automaticDecimals ? 2 : places)) + "E+00"
        case type("CURRENCY"), type("CUSTOM_CURRENCY"):
            let symbol = f.string("currency_code").flatMap(currencySymbol) ?? "$"
            return "\"\(symbol)\"" + decimals(places == automaticDecimals ? 2 : places)
        case type("FRACTION"):
            let accuracy = f.int("fraction_accuracy") ?? 2
            return accuracy <= 1 ? "# ?/?" : "# ??/??"
        case type("TEXT"), type("CUSTOM_TEXT"): return "@"
        case type("DATE"), type("CUSTOM_DATE"):
            guard let pattern = f.string("date_time_format"), !pattern.isEmpty else { return "yyyy-mm-dd" }
            return excelDatePattern(pattern)
        case type("DURATION"): return "[h]:mm:ss"
        case type("BOOLEAN"): return NumberFormat.general
        case type("CUSTOM_NUMBER"), type("CUSTOM_TEXT"):
            // the description names an entry of the document's custom-format list; without it there is nothing to say
            if let text = f.string("custom_format_string"), !text.isEmpty { return text }
            return kind == type("CUSTOM_TEXT") ? "@" : nil
        default: return nil                       // rating, checkbox, base-n, popup: Excel has no equivalent
        }
    }

    /// The other way: an Excel code as the fields of a `TSK.FormatStructArchive`, or nil when Numbers has no
    /// description for it (the writer then leaves the cell in General and says so).
    static func archive(for code: String) -> ProtoMessage? {
        var f = ProtoMessage(typeName: "TSK.FormatStructArchive")
        let plain = code.trimmingCharacters(in: .whitespaces)
        guard plain != NumberFormat.general, !plain.isEmpty else { return nil }
        if plain == "@" {
            f.set("format_type", int: type("TEXT") ?? 260)
            return f
        }
        if NumberFormat.isDateFormat(plain) {
            f.set("format_type", int: type("CUSTOM_DATE") ?? 272)
            f.set("date_time_format", string: numbersDatePattern(plain))
            return f
        }
        // a numeric code: the first section decides, and its shape gives the decimals / grouping / percentage
        let section = plain.split(separator: ";", maxSplits: 1).first.map(String.init) ?? plain
        let body = section.replacingOccurrences(of: "\"", with: "")
        let decimals = body.split(separator: ".", maxSplits: 1).dropFirst().first.map { $0.filter { $0 == "0" || $0 == "#" }.count } ?? 0
        let grouping = body.contains("#,##")
        if body.hasSuffix("%") {
            f.set("format_type", int: type("PERCENT") ?? 258)
        } else if body.uppercased().contains("E+") {
            f.set("format_type", int: type("SCIENTIFIC") ?? 259)
        } else if body.contains("/") {
            f.set("format_type", int: type("FRACTION") ?? 262)
            f.set("fraction_accuracy", int: body.contains("??") ? 2 : 1)
            return f
        } else if let symbol = body.first(where: { "$¥€£".contains($0) }) {
            f.set("format_type", int: type("CURRENCY") ?? 257)
            f.set("currency_code", string: currencyCode(symbol))
        } else if body.contains("0") || body.contains("#") {
            f.set("format_type", int: type("DECIMAL") ?? 256)
        } else {
            return nil
        }
        f.set("decimal_places", int: decimals)
        f.set("show_thousands_separator", bool: grouping)
        return f
    }

    /// True when the code carries a `[…]` directive that is not an elapsed-time marker — a colour or a condition,
    /// neither of which a Numbers format describes.
    static func hasDirective(_ code: String) -> Bool {
        var i = code.startIndex
        while let open = code[i...].firstIndex(of: "["), let close = code[open...].firstIndex(of: "]") {
            let body = String(code[code.index(after: open)..<close]).lowercased()
            if !["h", "hh", "m", "mm", "s", "ss"].contains(body) { return true }
            i = code.index(after: close)
            if i >= code.endIndex { break }
        }
        return false
    }

    static let symbols: [String: String] = ["USD": "$", "JPY": "¥", "EUR": "€", "GBP": "£", "CNY": "¥", "KRW": "₩"]
    static func currencySymbol(_ code: String) -> String? { symbols[code] ?? (code.isEmpty ? nil : code) }
    static func currencyCode(_ symbol: Character) -> String {
        symbols.first { $0.value == String(symbol) }?.key ?? "USD"
    }

    /// A Unicode (CLDR) date pattern as Excel's own, run by run. The two agree on `dd` and on `mmm`; they differ
    /// on the year (CLDR's `y` is "as many digits as it takes", Excel wants `yyyy`), on the hour (`H` / `h`) and on
    /// the am/pm marker.
    static func excelDatePattern(_ pattern: String) -> String {
        var out = ""
        var afterHour = false
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let ch = pattern[i]
            var run = 0
            var j = i
            while j < pattern.endIndex, pattern[j] == ch { run += 1; j = pattern.index(after: j) }
            switch ch {
            case "y": out += String(repeating: "y", count: run == 2 ? 2 : 4)
            case "M": out += String(repeating: "m", count: run)
            case "d": out += String(repeating: "d", count: run)
            case "E": out += String(repeating: "d", count: Swift.max(3, run))
            case "H", "h": out += String(repeating: "h", count: run); afterHour = true
            case "m": out += String(repeating: "m", count: run)
            case "s": out += String(repeating: "s", count: run)
            case "a": out += "AM/PM"
            case "'":                                       // a CLDR quoted literal
                j = pattern.index(after: i)
                while j < pattern.endIndex, pattern[j] != "'" { out.append(pattern[j]); j = pattern.index(after: j) }
                if j < pattern.endIndex { j = pattern.index(after: j) }
            default:
                out += String(repeating: String(ch), count: run)
                if ch != ":" { afterHour = false }
            }
            _ = afterHour
            i = j
        }
        return out
    }

    /// The inverse, as far as the two patterns agree.
    static func numbersDatePattern(_ code: String) -> String {
        var out = ""
        var afterHour = false
        var i = code.startIndex
        while i < code.endIndex {
            let ch = code[i]
            if code[i...].hasPrefix("AM/PM") { out.append("a"); i = code.index(i, offsetBy: 5); continue }
            switch ch {
            case "y", "d", "s": out.append(ch)
            case "h": out.append("H"); afterHour = true
            case "m": out.append(afterHour ? "m" : "M")
            case ":": out.append(":")
            default: out.append(ch); afterHour = false
            }
            i = code.index(after: i)
        }
        return out
    }
}

/// Builds the style and format lists of one table on the way out.
///
/// Numbers has no "cell format" record: a cell names an entry of its table's style list, and each entry is a style
/// archive that *varies* one of the table's own defaults. So every distinct `CellStyle` becomes two new archives —
/// a `TSWP.ParagraphStyleArchive` under the table's `body_text_style` and a `TST.CellStyleArchive` under its
/// `body_cell_style` — written beside the template's own styles in `Index/DocumentStylesheet.iwa`. Number formats
/// are the same shape again, as `TSK.FormatStructArchive` entries of the format list.
struct NumbersStyleWriter {
    let doc: NumbersDocument
    private let textParent: Int?
    private let cellParent: Int?
    private let stylesheet: Int?
    /// Where new style archives go: the file the template's own styles live in.
    static let stylesheetFile = "Index/DocumentStylesheet.iwa"

    private var textKeys: [CellStyle: Int] = [:]
    private var cellKeys: [CellStyle: Int] = [:]
    private var formatKeys: [String: Int] = [:]
    private(set) var styleEntries: [ProtoMessage] = []
    private(set) var formatEntries: [ProtoMessage] = []
    /// Number-format codes Numbers has no description for; the writer reports them once each.
    private(set) var unexpressibleFormats: [String] = []
    /// Codes Numbers can only half describe — a second section for negatives, a colour, a condition.
    private(set) var partialFormats: [String] = []

    init(doc: NumbersDocument, model: ProtoMessage) {
        self.doc = doc
        textParent = model.reference("body_text_style")
        cellParent = model.reference("body_cell_style")
        stylesheet = textParent.flatMap { doc.object($0)?.message("super")?.reference("stylesheet") }
    }

    /// The style-list keys a cell needs, minting the archives the first time a style is met.
    mutating func keys(for style: CellStyle) throws -> (cell: Int?, text: Int?) {
        guard style != .default else { return (nil, nil) }
        var text: Int?
        var cell: Int?
        if let properties = characterProperties(style), let parent = textParent {
            if let k = textKeys[style] { text = k } else {
                var para = ProtoMessage(typeName: "TSWP.ParagraphStyleArchive")
                para.set("super", message: superArchive(parent: parent))
                para.set("override_count", int: properties.overrides)
                para.set("char_properties", message: properties.char)
                if let p = properties.para { para.set("para_properties", message: p) }
                let id = try doc.add(para, file: NumbersStyleWriter.stylesheetFile)
                text = addEntry(id)
                textKeys[style] = text
            }
        }
        if let properties = cellProperties(style), let parent = cellParent {
            if let k = cellKeys[style] { cell = k } else {
                var archive = ProtoMessage(typeName: "TST.CellStyleArchive")
                archive.set("super", message: superArchive(parent: parent))
                archive.set("override_count", int: properties.overrides)
                archive.set("cell_properties", message: properties.cell)
                let id = try doc.add(archive, file: NumbersStyleWriter.stylesheetFile)
                cell = addEntry(id)
                cellKeys[style] = cell
            }
        }
        return (cell, text)
    }

    /// The format-list key for a number-format code, or nil when Numbers cannot describe it.
    mutating func formatKey(for code: String) -> Int? {
        if let k = formatKeys[code] { return k >= 0 ? k : nil }
        guard let archive = NumbersFormat.archive(for: code) else {
            formatKeys[code] = -1
            if code != NumberFormat.general { unexpressibleFormats.append(code) }
            return nil
        }
        // Numbers describes one presentation, not Excel's four sections and their colours and conditions
        if code.contains(";") || NumbersFormat.hasDirective(code) { partialFormats.append(code) }
        let key = formatEntries.count + 1
        var entry = ProtoMessage(typeName: "TST.TableDataList.ListEntry")
        entry.set("key", int: key); entry.set("refcount", int: 1); entry.set("format", message: archive)
        formatEntries.append(entry)
        formatKeys[code] = key
        return key
    }

    private mutating func addEntry(_ objectID: Int) -> Int {
        let key = styleEntries.count + 1
        var entry = ProtoMessage(typeName: "TST.TableDataList.ListEntry")
        entry.set("key", int: key); entry.set("refcount", int: 1); entry.set("reference", reference: objectID)
        styleEntries.append(entry)
        return key
    }

    private func superArchive(parent: Int) -> ProtoMessage {
        var s = ProtoMessage(typeName: "TSS.StyleArchive")
        s.set("parent", reference: parent)
        s.set("is_variation", bool: true)
        if let stylesheet { s.set("stylesheet", reference: stylesheet) }
        return s
    }

    /// The character / paragraph overrides of a style, or nil when it says nothing about text.
    private func characterProperties(_ style: CellStyle) -> (char: ProtoMessage, para: ProtoMessage?, overrides: Int)? {
        var char = ProtoMessage(typeName: "TSWP.CharacterStylePropertiesArchive")
        var overrides = 0
        let font = style.font, base = Font.default
        if font.bold { char.set("bold", bool: true); overrides += 1 }
        if font.italic { char.set("italic", bool: true); overrides += 1 }
        if let size = font.size, size != base.size { char.set("font_size", float: Float(size)); overrides += 1 }
        if let name = font.name, name != base.name { char.set("font_name", string: name); overrides += 1 }
        if case .rgb(let hex)? = font.color, let colour = NumbersStyleWriter.color(hex) {
            char.set("font_color", message: colour); overrides += 1
        }
        if let underline = font.underline { char.set("underline", int: underline == .double || underline == .doubleAccounting ? 2 : 1); overrides += 1 }
        if font.strikethrough { char.set("strikethru", int: 1); overrides += 1 }

        var para: ProtoMessage?
        if let horizontal = style.alignment.horizontal {
            let value: Int?
            switch horizontal {
            case .left: value = 0
            case .right: value = 1
            case .center, .centerContinuous: value = 2
            case .justify, .distributed: value = 3
            case .general, .fill: value = nil
            }
            if let value {
                var p = ProtoMessage(typeName: "TSWP.ParagraphStylePropertiesArchive")
                p.set("alignment", int: value)
                para = p
                overrides += 1
            }
        }
        return overrides == 0 ? nil : (char, para, overrides)
    }

    /// The cell overrides of a style (fill, borders, vertical alignment, wrapping), or nil when it says none.
    private func cellProperties(_ style: CellStyle) -> (cell: ProtoMessage, overrides: Int)? {
        var cell = ProtoMessage(typeName: "TST.CellStylePropertiesArchive")
        var overrides = 0
        if style.fill.patternType != .none || style.fill.gradientFill != nil,
           case .rgb(let hex)? = style.fill.foregroundColor ?? style.fill.backgroundColor, let colour = NumbersStyleWriter.color(hex) {
            var fill = ProtoMessage(typeName: "TSD.FillArchive")
            fill.set("color", message: colour)
            cell.set("cell_fill", message: fill)
            overrides += 1
        }
        if style.alignment.wrapText { cell.set("text_wrap", bool: true); overrides += 1 }
        if let vertical = style.alignment.vertical {
            switch vertical {
            case .top: cell.set("vertical_alignment", int: 0)
            case .center, .justify, .distributed: cell.set("vertical_alignment", int: 1)
            case .bottom: cell.set("vertical_alignment", int: 2)
            }
            overrides += 1
        }
        for (name, side) in [("top_stroke", style.border.top), ("bottom_stroke", style.border.bottom),
                             ("left_stroke", style.border.left), ("right_stroke", style.border.right)] {
            guard let stroke = NumbersStyleWriter.stroke(side) else { continue }
            cell.set(name, message: stroke)
            overrides += 1
        }
        return overrides == 0 ? nil : (cell, overrides)
    }

    /// "AARRGGBB" → `TSP.Color` with 0…1 components, the way Numbers keeps them.
    static func color(_ hex: String) -> ProtoMessage? {
        let text = hex.count == 6 ? "FF" + hex : hex
        guard text.count == 8, let value = UInt32(text, radix: 16) else { return nil }
        var m = ProtoMessage(typeName: "TSP.Color")
        m.set("model", int: NumbersSchema.shared.enumValue("TSP.Color.ColorModel", "rgb") ?? 1)
        m.set("r", float: Float((value >> 16) & 0xFF) / 255)
        m.set("g", float: Float((value >> 8) & 0xFF) / 255)
        m.set("b", float: Float(value & 0xFF) / 255)
        m.set("a", float: Float((value >> 24) & 0xFF) / 255)
        return m
    }

    /// A border side as a `TSD.StrokeArchive`; nil for "no border".
    static func stroke(_ side: Side) -> ProtoMessage? {
        guard let style = side.style else { return nil }
        let width: Double
        switch style {
        case .hair: width = 0.25
        case .thin, .dotted, .dashed, .dashDot, .dashDotDot: width = 1
        case .medium, .mediumDashed, .mediumDashDot, .mediumDashDotDot, .slantDashDot, .double: width = 2
        case .thick: width = 3
        }
        var m = ProtoMessage(typeName: "TSD.StrokeArchive")
        m.set("width", float: Float(width))
        if case .rgb(let hex)? = side.color, let colour = color(hex) { m.set("color", message: colour) }
        else if let colour = color("FF000000") { m.set("color", message: colour) }
        return m
    }
}
