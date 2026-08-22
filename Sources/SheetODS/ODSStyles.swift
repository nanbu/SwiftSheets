import Foundation
import SheetCore

/// Attribute lookup tolerant of the producer's prefix choice: the exact qualified name first, then any prefix with
/// the same local name — except `calcext:` (LibreOffice's `calcext:value-type` shadows `office:value-type`).
enum ODSAttr {
    static let officeNS = "urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    static let tableNS = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"

    /// True when the root element binds the standard prefixes, so exact lookups suffice (the lenient scan is only
    /// for producers that chose other prefixes).
    static func usesStandardPrefixes(_ root: [String: String]) -> Bool {
        root["xmlns:office"] == officeNS && root["xmlns:table"] == tableNS
    }

    static func get(_ a: [String: String], _ qualified: String, lenient: Bool = true) -> String? {
        if let v = a[qualified] { return v }
        guard lenient else { return nil }
        let local = XML.local(qualified)
        for (k, v) in a where !k.hasPrefix("calcext:") && XML.local(k) == local { return v }
        return nil
    }
    static func int(_ a: [String: String], _ qualified: String) -> Int? { get(a, qualified).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
    static func bool(_ a: [String: String], _ qualified: String) -> Bool? {
        guard let v = get(a, qualified)?.lowercased() else { return nil }
        return v == "true" ? true : v == "false" ? false : nil
    }
}

/// One `style:style` (or `style:default-style`) as its raw property maps, resolved into a `CellStyle` on demand.
struct ODSRawStyle {
    var family = ""
    var parent: String?
    var dataStyleName: String?
    var masterPage: String?
    var text: [String: String] = [:]
    var cell: [String: String] = [:]
    var paragraph: [String: String] = [:]
    var column: [String: String] = [:]
    var row: [String: String] = [:]
    var table: [String: String] = [:]
}

/// The styles of a document (styles.xml named styles + content.xml automatic styles + font faces + data styles),
/// fed by the SAX parsers and queried by the content reader.
final class ODSStyleCatalog {
    var fontFaces: [String: String] = [:]
    var styles: [String: ODSRawStyle] = [:]
    var dataStyles: [String: ODSDataStyle] = [:]
    /// `style:default-style style:family="table-cell"` — the document's base font.
    var defaultCellStyle = ODSRawStyle()
    /// Data styles whose Excel code could not be reconstructed (reported once each).
    private(set) var unmappedDataStyles: [String] = []
    private var resolved: [String: CellStyle] = [:]

    // MARK: - Feeding (called by the parsers while inside office:styles / office:automatic-styles / office:font-face-decls)

    private var current: ODSRawStyle?
    private var currentName: String?
    private var isDefaultStyle = false
    private var currentData: ODSDataStyle?
    private var currentDataName: String?
    private var dataText = ""
    private var inDataText = false

    func start(_ name: String, _ a: [String: String]) {
        switch name {
        case "font-face":
            if let n = ODSAttr.get(a, "style:name") {
                let family = ODSAttr.get(a, "svg:font-family") ?? ODSAttr.get(a, "fo:font-family") ?? n
                fontFaces[n] = family.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
        case "style", "default-style":
            var s = ODSRawStyle()
            s.family = ODSAttr.get(a, "style:family") ?? ""
            s.parent = ODSAttr.get(a, "style:parent-style-name")
            s.dataStyleName = ODSAttr.get(a, "style:data-style-name")
            s.masterPage = ODSAttr.get(a, "style:master-page-name")
            current = s
            currentName = ODSAttr.get(a, "style:name")
            isDefaultStyle = name == "default-style"
        case "text-properties": if current != nil { current!.text.merge(a) { _, new in new } } else if currentData != nil { break }
        case "table-cell-properties": current?.cell.merge(a) { _, new in new }
        case "paragraph-properties": current?.paragraph.merge(a) { _, new in new }
        case "table-column-properties": current?.column.merge(a) { _, new in new }
        case "table-row-properties": current?.row.merge(a) { _, new in new }
        case "table-properties": current?.table.merge(a) { _, new in new }
        case "number-style", "percentage-style", "currency-style", "date-style", "time-style", "boolean-style", "text-style":
            guard let kind = ODSDataStyle.Kind(rawValue: name) else { return }
            var d = ODSDataStyle(kind: kind)
            d.truncateOnOverflow = ODSAttr.bool(a, "number:truncate-on-overflow") ?? true
            currentData = d
            currentDataName = ODSAttr.get(a, "style:name")
        case "number":
            let decimals = ODSAttr.int(a, "number:decimal-places") ?? 0
            currentData?.items.append(.number(decimals: decimals, minDecimals: ODSAttr.int(a, "number:min-decimal-places") ?? decimals,
                                              minInteger: ODSAttr.int(a, "number:min-integer-digits") ?? 1, grouping: ODSAttr.bool(a, "number:grouping") ?? false))
        case "scientific-number":
            currentData?.items.append(.scientific(decimals: ODSAttr.int(a, "number:decimal-places") ?? 0, minInteger: ODSAttr.int(a, "number:min-integer-digits") ?? 1,
                                                  exponentDigits: ODSAttr.int(a, "number:min-exponent-digits") ?? 2))
        case "text" where currentData != nil: inDataText = true; dataText = ""
        case "currency-symbol" where currentData != nil: inDataText = true; dataText = ""
        case "year": currentData?.items.append(.year(long: ODSAttr.get(a, "number:style") == "long"))
        case "month": currentData?.items.append(.month(long: ODSAttr.get(a, "number:style") == "long", textual: ODSAttr.bool(a, "number:textual") ?? false))
        case "day": currentData?.items.append(.day(long: ODSAttr.get(a, "number:style") == "long"))
        case "day-of-week": currentData?.items.append(.dayOfWeek(long: ODSAttr.get(a, "number:style") == "long"))
        case "hours": currentData?.items.append(.hours(long: ODSAttr.get(a, "number:style") == "long"))
        case "minutes": currentData?.items.append(.minutes(long: ODSAttr.get(a, "number:style") == "long"))
        case "seconds": currentData?.items.append(.seconds(long: ODSAttr.get(a, "number:style") == "long", decimals: ODSAttr.int(a, "number:decimal-places") ?? 0))
        case "am-pm": currentData?.items.append(.amPm)
        case "boolean": currentData?.items.append(.boolean)
        case "text-content": currentData?.items.append(.textContent)
        case "era", "quarter", "week-of-year", "fraction", "embedded-text", "fill-character":
            currentData?.items.append(.unsupported(name))
        case "map": if currentData != nil { currentData!.hasMap = true }
        default: break
        }
    }

    func text(_ s: String) { if inDataText { dataText += s } }

    func end(_ name: String) {
        switch name {
        case "style", "default-style":
            if let s = current {
                if isDefaultStyle { if s.family == "table-cell" { defaultCellStyle = s } }
                else if let n = currentName { styles[n] = s }
            }
            current = nil; currentName = nil
        case "text", "currency-symbol":
            if inDataText { currentData?.items.append(.text(dataText)); inDataText = false }
        case "number-style", "percentage-style", "currency-style", "date-style", "time-style", "boolean-style", "text-style":
            if let d = currentData, let n = currentDataName { dataStyles[n] = d }
            currentData = nil; currentDataName = nil
        default: break
        }
    }

    // MARK: - Queries

    func columnWidthCharacters(_ styleName: String?) -> Double? {
        guard let n = styleName, let s = styles[n], let w = ODSAttr.get(s.column, "style:column-width") else { return nil }
        return ODSLength.characters(w)
    }

    /// Row height in points — only when the style asks for that height (`style:use-optimal-row-height="false"`
    /// or unset); an "optimal" height is the application's own measurement, not a setting.
    func rowHeightPoints(_ styleName: String?) -> Double? {
        guard let n = styleName, let s = styles[n], let h = ODSAttr.get(s.row, "style:row-height") else { return nil }
        if ODSAttr.bool(s.row, "style:use-optimal-row-height") == true { return nil }
        return ODSLength.points(h).map { ($0 * 100).rounded() / 100 }
    }

    func isTableHidden(_ styleName: String?) -> Bool {
        guard let n = styleName, let s = styles[n] else { return false }
        return ODSAttr.bool(s.table, "table:display") == false
    }

    /// The Excel code of a data style; "General" (and a note in `unmappedDataStyles`) when it has no Excel form.
    func numberFormat(dataStyleName: String) -> String {
        guard let d = dataStyles[dataStyleName] else { return NumberFormat.general }
        if let code = d.excelCode { return code }
        if !unmappedDataStyles.contains(dataStyleName) { unmappedDataStyles.append(dataStyleName) }
        return NumberFormat.general
    }

    private var sharedStyles: [String: SharedStyle] = [:]
    /// The resolved style as one shared instance per style name — a column of cells naming the same automatic style
    /// should not each carry their own 384-byte copy.
    func sharedCellStyle(named name: String?) -> SharedStyle? {
        guard let name else { return nil }
        if let existing = sharedStyles[name] { return existing }
        let style = cellStyle(named: name)
        guard style != .default else { return nil }
        let made = SharedStyle(style)
        sharedStyles[name] = made
        return made
    }

    /// The fully resolved cell style. "Default" / unknown names are the model default.
    func cellStyle(named name: String?) -> CellStyle {
        guard let name, name != "Default", styles[name] != nil else { return .default }
        if let r = resolved[name] { return r }
        var chain: [ODSRawStyle] = []
        var cursor: String? = name
        var seen = Set<String>()
        while let n = cursor, n != "Default", let s = styles[n], seen.insert(n).inserted { chain.append(s); cursor = s.parent }
        var style = CellStyle.default
        // the document default font is the base of every explicit style
        apply(text: defaultCellStyle.text, to: &style.font)
        for raw in chain.reversed() {
            apply(text: raw.text, to: &style.font)
            apply(cell: raw.cell, to: &style)
            apply(paragraph: raw.paragraph, to: &style)
            if let ds = raw.dataStyleName { style.numberFormat = numberFormat(dataStyleName: ds) }
        }
        resolved[name] = style
        return style
    }

    private func apply(text a: [String: String], to font: inout Font) {
        if let n = ODSAttr.get(a, "style:font-name") ?? ODSAttr.get(a, "fo:font-family") {
            let family = fontFaces[n] ?? n.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if family != font.name { font.name = family; font.scheme = nil; font.family = nil }
        }
        if let s = ODSAttr.get(a, "fo:font-size"), let pt = ODSLength.points(s) { font.size = (pt * 100).rounded() / 100 }
        if let w = ODSAttr.get(a, "fo:font-weight") { font.bold = w == "bold" || (Int(w).map { $0 >= 600 } ?? false) }
        if let st = ODSAttr.get(a, "fo:font-style") { font.italic = st == "italic" || st == "oblique" }
        if let c = ODSAttr.get(a, "fo:color"), c.hasPrefix("#") { font.color = Color(hex: c) }
        if let u = ODSAttr.get(a, "style:text-underline-style") { font.underline = u == "none" ? nil : u == "double" ? .double : .single }
        if let lt = ODSAttr.get(a, "style:text-line-through-style") { font.strikethrough = lt != "none" }
    }

    private func apply(cell a: [String: String], to style: inout CellStyle) {
        if let bg = ODSAttr.get(a, "fo:background-color") {
            style.fill = bg.hasPrefix("#") ? .solid(Color(hex: bg)) : .none
        }
        if let b = ODSAttr.get(a, "fo:border") {
            let side = ODSBorder.side(b)
            style.border.left = side; style.border.right = side; style.border.top = side; style.border.bottom = side
        }
        if let b = ODSAttr.get(a, "fo:border-left") { style.border.left = ODSBorder.side(b) }
        if let b = ODSAttr.get(a, "fo:border-right") { style.border.right = ODSBorder.side(b) }
        if let b = ODSAttr.get(a, "fo:border-top") { style.border.top = ODSBorder.side(b) }
        if let b = ODSAttr.get(a, "fo:border-bottom") { style.border.bottom = ODSBorder.side(b) }
        if let v = ODSAttr.get(a, "style:vertical-align") {
            switch v {
            case "top": style.alignment.vertical = .top
            case "middle": style.alignment.vertical = .center
            case "bottom": style.alignment.vertical = .bottom
            default: style.alignment.vertical = nil
            }
        }
        if let w = ODSAttr.get(a, "fo:wrap-option") { style.alignment.wrapText = w == "wrap" }
        if let s = ODSAttr.bool(a, "style:shrink-to-fit") { style.alignment.shrinkToFit = s }
        if let r = ODSAttr.get(a, "style:rotation-angle"), let deg = Int(r.replacingOccurrences(of: "deg", with: "")) { style.alignment.textRotation = deg }
        if let p = ODSAttr.get(a, "style:cell-protect") {
            style.protection.locked = p != "none" && p != "formula-hidden"
            style.protection.hidden = p == "hidden-and-protected" || p == "formula-hidden"
        }
    }

    private func apply(paragraph a: [String: String], to style: inout CellStyle) {
        if let t = ODSAttr.get(a, "fo:text-align") {
            switch t {
            case "start", "left": style.alignment.horizontal = .left
            case "end", "right": style.alignment.horizontal = .right
            case "center": style.alignment.horizontal = .center
            case "justify": style.alignment.horizontal = .justify
            default: break
            }
        }
    }
}

/// `fo:border` values ("0.74pt solid #888888") ⇄ `Side`.
enum ODSBorder {
    static func side(_ value: String) -> Side {
        let parts = value.split(separator: " ").map(String.init)
        guard !parts.isEmpty, parts[0] != "none", parts[0] != "hidden" else { return Side() }
        var width: Double?
        var keyword = "solid"
        var color: Color?
        for p in parts {
            if p.hasPrefix("#") { color = Color(hex: p) }
            else if let pt = ODSLength.points(p) { width = pt }
            else { keyword = p }
        }
        let w = width ?? 0.75
        let style: Side.Style
        switch keyword {
        case "double", "double-thin": style = .double
        case "dotted": style = .dotted
        case "dashed", "fine-dashed": style = w >= 1.2 ? .mediumDashed : .dashed
        case "dash-dot": style = w >= 1.2 ? .mediumDashDot : .dashDot
        case "dash-dot-dot": style = w >= 1.2 ? .mediumDashDotDot : .dashDotDot
        default: style = w <= 0.3 ? .hair : w < 1.2 ? .thin : w < 2.2 ? .medium : .thick
        }
        return Side(style: style, color: color)
    }

    /// Returns nil for an unset side. `fallbackColor` is used for non-RGB colours (the caller warns).
    static func value(_ side: Side, nonRGB: inout Bool) -> String? {
        guard let st = side.style else { return nil }
        let spec: String
        switch st {
        case .thin: spec = "0.75pt solid"
        case .medium: spec = "1.75pt solid"
        case .thick: spec = "2.5pt solid"
        case .hair: spec = "0.05pt solid"
        case .double: spec = "1.5pt double"
        case .dotted: spec = "0.75pt dotted"
        case .dashed: spec = "0.75pt dashed"
        case .dashDot: spec = "0.75pt dash-dot"
        case .dashDotDot: spec = "0.75pt dash-dot-dot"
        case .mediumDashed: spec = "1.75pt dashed"
        case .mediumDashDot, .slantDashDot: spec = "1.75pt dash-dot"
        case .mediumDashDotDot: spec = "1.75pt dash-dot-dot"
        }
        return spec + " " + ODSColor.hex(side.color, nonRGB: &nonRGB)
    }
}

enum ODSColor {
    /// "#rrggbb" for an RGB colour; black for theme / indexed / auto / nil (the caller records `nonRGB`).
    static func hex(_ color: Color?, nonRGB: inout Bool) -> String {
        switch color {
        case .rgb(let v)?: return "#" + Units.shortColor(v).lowercased()
        case nil, .auto?: return "#000000"
        default: nonRGB = true; return "#000000"
        }
    }
}
