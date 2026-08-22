import Foundation

/// ARGB ("FF2F6FD0"), theme index, or indexed palette — the three ways OOXML names a color.
public enum Color: Hashable, Sendable {
    case rgb(String)
    case theme(Int, tint: Double = 0)
    case indexed(Int)
    case auto

    public static let black = Color.rgb("FF000000")
    public static let white = Color.rgb("FFFFFFFF")

    /// Accepts "RRGGBB" or "AARRGGBB".
    public init(hex: String) {
        let h = hex.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        self = .rgb(h.count == 6 ? "FF" + h : h)
    }
}

public struct Font: Hashable, Sendable {
    public var name: String?
    public var size: Double?
    public var bold = false
    public var italic = false
    public var underline: Underline?
    public var strikethrough = false
    public var color: Color?
    public var family: Int?
    public var scheme: String?
    public var vertAlign: String?
    public var charset: Int?

    public enum Underline: String, Sendable { case single, double, singleAccounting, doubleAccounting }

    public init(name: String? = nil, size: Double? = nil, bold: Bool = false, italic: Bool = false, underline: Underline? = nil,
                strikethrough: Bool = false, color: Color? = nil) {
        self.name = name; self.size = size; self.bold = bold; self.italic = italic; self.underline = underline
        self.strikethrough = strikethrough; self.color = color
    }

    /// The default font Excel assumes when none is set (openpyxl's DEFAULT_FONT: Calibri 11, family 2, theme color 1, minor scheme).
    public static let `default`: Font = { var f = Font(name: "Calibri", size: 11, color: .theme(1)); f.family = 2; f.scheme = "minor"; return f }()
}

public struct PatternFill: Hashable, Sendable {
    public enum PatternType: String, Sendable {
        case none, solid, gray125, gray0625, darkGray, mediumGray, lightGray, darkHorizontal, darkVertical, darkDown, darkUp, darkGrid, darkTrellis,
             lightHorizontal, lightVertical, lightDown, lightUp, lightGrid, lightTrellis
    }
    public var patternType: PatternType
    public var foregroundColor: Color?
    public var backgroundColor: Color?

    public init(patternType: PatternType = .none, foregroundColor: Color? = nil, backgroundColor: Color? = nil) {
        self.patternType = patternType; self.foregroundColor = foregroundColor; self.backgroundColor = backgroundColor
    }

    /// A solid fill of one color (the common case).
    public static func solid(_ color: Color) -> PatternFill { PatternFill(patternType: .solid, foregroundColor: color, backgroundColor: color) }
    public static let none = PatternFill()
}

public struct Side: Hashable, Sendable {
    public enum Style: String, Sendable {
        case thin, medium, thick, double, hair, dotted, dashed, dashDot, dashDotDot, mediumDashed, mediumDashDot, mediumDashDotDot, slantDashDot
    }
    public var style: Style?
    public var color: Color?
    public init(style: Style? = nil, color: Color? = nil) { self.style = style; self.color = color }
}

public struct Border: Hashable, Sendable {
    public var left = Side(), right = Side(), top = Side(), bottom = Side(), diagonal = Side()
    public var diagonalUp = false, diagonalDown = false
    /// Excel's `outline` attribute (default true; written only when false).
    public var outline = true
    public init(left: Side = Side(), right: Side = Side(), top: Side = Side(), bottom: Side = Side(), diagonal: Side = Side(),
                diagonalUp: Bool = false, diagonalDown: Bool = false, outline: Bool = true) {
        self.left = left; self.right = right; self.top = top; self.bottom = bottom; self.diagonal = diagonal
        self.diagonalUp = diagonalUp; self.diagonalDown = diagonalDown; self.outline = outline
    }
    /// The same side on all four edges.
    public static func all(_ side: Side) -> Border { Border(left: side, right: side, top: side, bottom: side) }
    public static let none = Border()

    /// openpyxl's `border1 + border2`: for every side, attributes this border leaves unset are taken from `other`.
    public func combined(with other: Border) -> Border {
        func side(_ a: Side, _ b: Side) -> Side { Side(style: a.style ?? b.style, color: a.color ?? b.color) }
        return Border(left: side(left, other.left), right: side(right, other.right), top: side(top, other.top), bottom: side(bottom, other.bottom),
                      diagonal: side(diagonal, other.diagonal), diagonalUp: diagonalUp || other.diagonalUp, diagonalDown: diagonalDown || other.diagonalDown,
                      outline: outline || other.outline)
    }
}

public struct Alignment: Hashable, Sendable {
    public enum Horizontal: String, Sendable { case general, left, center, right, fill, justify, centerContinuous, distributed }
    public enum Vertical: String, Sendable { case top, center, bottom, justify, distributed }
    public var horizontal: Horizontal?
    public var vertical: Vertical?
    public var wrapText = false
    public var shrinkToFit = false
    public var indent = 0
    public var textRotation = 0
    public init(horizontal: Horizontal? = nil, vertical: Vertical? = nil, wrapText: Bool = false, shrinkToFit: Bool = false, indent: Int = 0, textRotation: Int = 0) {
        self.horizontal = horizontal; self.vertical = vertical; self.wrapText = wrapText; self.shrinkToFit = shrinkToFit; self.indent = indent; self.textRotation = textRotation
    }
    public static let none = Alignment()
}

public struct Protection: Hashable, Sendable {
    public var locked = true
    public var hidden = false
    public init(locked: Bool = true, hidden: Bool = false) { self.locked = locked; self.hidden = hidden }
}

/// Number formats (openpyxl.styles.numbers). Builtin ids 0–49 are fixed by the spec; custom codes get 164+.
public enum NumberFormat {
    public static let general = "General"
    public static let text = "@"
    public static let number = "0"
    public static let number00 = "0.00"
    public static let numberCommaSeparated1 = "#,##0.00"
    public static let numberCommaSeparated2 = "#,##0.00_-"
    public static let percentage = "0%"
    public static let percentage00 = "0.00%"
    public static let dateYYYYMMDD2 = "yyyy-mm-dd"
    public static let dateYYMMDD = "yy-mm-dd"
    public static let dateDDMMYY = "dd/mm/yy"
    public static let dateDMYSlash = "d/m/y"
    public static let dateDMYMinus = "d-m-y"
    public static let dateDMMinus = "d-m"
    public static let dateMYMinus = "m-y"
    public static let dateXLSX14 = "mm-dd-yy"
    public static let dateXLSX15 = "d-mmm-yy"
    public static let dateXLSX16 = "d-mmm"
    public static let dateXLSX17 = "mmm-yy"
    public static let dateXLSX22 = "m/d/yy h:mm"
    public static let dateDatetime = "yyyy-mm-dd h:mm:ss"
    public static let dateTime1 = "h:mm AM/PM"
    public static let dateTime2 = "h:mm:ss AM/PM"
    public static let dateTime3 = "h:mm"
    public static let dateTime4 = "h:mm:ss"
    public static let dateTime5 = "mm:ss"
    public static let dateTime6 = "h:mm:ss"
    public static let dateTime7 = "i:s.S"
    public static let dateTime8 = "h:mm:ss@"
    public static let dateTimedelta = "[hh]:mm:ss"
    public static let dateYYMMDDSlash = "yy/mm/dd@"
    public static let currencyUSDSimple = "\"$\"#,##0.00_-"
    public static let currencyUSD = "$#,##0_-"
    public static let currencyEURSimple = "[$EUR ]#,##0.00_-"
    /// Kept for source compatibility; same as `dateYYYYMMDD2`.
    public static let dateYYYYMMDD = dateYYYYMMDD2

    public static let builtin: [Int: String] = [
        0: "General", 1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00", 5: "\"$\"#,##0_);(\"$\"#,##0)", 6: "\"$\"#,##0_);[Red](\"$\"#,##0)",
        7: "\"$\"#,##0.00_);(\"$\"#,##0.00)", 8: "\"$\"#,##0.00_);[Red](\"$\"#,##0.00)", 9: "0%", 10: "0.00%", 11: "0.00E+00", 12: "# ?/?", 13: "# ??/??",
        14: "mm-dd-yy", 15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy", 18: "h:mm AM/PM", 19: "h:mm:ss AM/PM", 20: "h:mm", 21: "h:mm:ss", 22: "m/d/yy h:mm",
        37: "#,##0_);(#,##0)", 38: "#,##0_);[Red](#,##0)", 39: "#,##0.00_);(#,##0.00)", 40: "#,##0.00_);[Red](#,##0.00)",
        41: "_(* #,##0_);_(* \\(#,##0\\);_(* \"-\"_);_(@_)", 42: "_(\"$\"* #,##0_);_(\"$\"* \\(#,##0\\);_(\"$\"* \"-\"_);_(@_)",
        43: "_(* #,##0.00_);_(* \\(#,##0.00\\);_(* \"-\"??_);_(@_)", 44: "_(\"$\"* #,##0.00_)_(\"$\"* \\(#,##0.00\\)_(\"$\"* \"-\"??_)_(@_)",
        45: "mm:ss", 46: "[h]:mm:ss", 47: "mmss.0", 48: "##0.0E+0", 49: "@",
        // East Asian builtins Excel registers (ids 27–36, 50–58) — shown as their Japanese forms.
        27: "[$-404]e/m/d", 28: "[$-404]e\"年\"m\"月\"d\"日\"", 29: "[$-404]e\"年\"m\"月\"d\"日\"", 30: "m/d/yy", 31: "yyyy\"年\"m\"月\"d\"日\"",
        32: "h\"時\"mm\"分\"", 33: "h\"時\"mm\"分\"ss\"秒\"", 34: "yyyy\"年\"m\"月\"", 35: "m\"月\"d\"日\"", 36: "[$-404]e/m/d",
        50: "[$-404]e/m/d", 51: "[$-404]e\"年\"m\"月\"d\"日\"", 52: "yyyy\"年\"m\"月\"", 53: "m\"月\"d\"日\"", 54: "[$-404]e\"年\"m\"月\"d\"日\"",
        55: "yyyy\"年\"m\"月\"", 56: "m\"月\"d\"日\"", 57: "[$-404]e/m/d", 58: "[$-404]e\"年\"m\"月\"d\"日\"",
    ]
    package static let builtinIDs: [String: Int] = Dictionary(builtin.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    /// Ids below this are builtin; custom formats are numbered from here (openpyxl BUILTIN_FORMATS_MAX_SIZE).
    public static let firstCustomID = 164

    /// Builtin ids whose meaning depends on the reader's locale (the East Asian date / time formats). Files that
    /// reference them render differently in Excel, LibreOffice and Numbers, so writers spell the code out instead.
    public static let localeDependentIDs: Set<Int> = Set(27...36).union(Set(50...58))

    /// The code of a builtin format id (openpyxl `builtin_format_code`).
    public static func builtinCode(_ id: Int) -> String? { builtin[id] }
    /// The builtin id of a code, if the code is one of the spec's builtins (openpyxl `builtin_format_id`).
    public static func builtinID(_ code: String) -> Int? { builtinIDs[code] }
    public static func isBuiltin(_ code: String) -> Bool { builtinIDs[code] != nil }

    /// Removes quoted literals and bracketed sections other than `[h]` / `[m]` / `[s]` (openpyxl STRIP_RE).
    static func stripLiterals(_ code: String) -> String {
        var out = "", i = code.startIndex
        while i < code.endIndex {
            let ch = code[i]
            if ch == "\"" {
                guard let close = code[code.index(after: i)...].firstIndex(of: "\"") else { out.append(contentsOf: code[i...]); break }
                i = code.index(after: close); continue
            }
            if ch == "[" {
                guard let close = code[i...].firstIndex(of: "]") else { out.append(contentsOf: code[i...]); break }
                let inner = code[code.index(after: i)..<close].lowercased()
                if ["h", "hh", "m", "mm", "s", "ss"].contains(inner) { out.append(contentsOf: code[i...close]) }
                i = code.index(after: close); continue
            }
            out.append(ch); i = code.index(after: i)
        }
        return out
    }

    /// True when the code formats a date or time: after literal stripping, a `d m h y s` token not escaped by `_` or `\`
    /// (openpyxl `is_date_format`). Only the first section (positive values) counts.
    public static func isDateFormat(_ code: String) -> Bool {
        let first = code.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init) ?? code
        let stripped = Array(stripLiterals(first))
        for (i, ch) in stripped.enumerated() where "dmhysDMHYS".contains(ch) {
            if i > 0, stripped[i - 1] == "_" || stripped[i - 1] == "\\" { continue }
            return true
        }
        return false
    }

    /// True when the first section uses elapsed-time brackets such as `[h]:mm:ss`, `[mm]:ss`, `[ss].0` (openpyxl `is_timedelta_format`).
    public static func isTimedeltaFormat(_ code: String) -> Bool {
        let first = code.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init)?.lowercased() ?? code.lowercased()
        var i = first.startIndex
        while let open = first[i...].firstIndex(of: "[") {
            guard let close = first[open...].firstIndex(of: "]") else { return false }
            let inner = first[first.index(after: open)..<close]
            if ["h", "hh", "m", "mm", "s", "ss"].contains(inner) { return true }
            i = first.index(after: close)
        }
        return false
    }

    public enum Kind: String, Sendable { case date, time, datetime }

    /// Whether a date format shows a date, a time, or both (openpyxl `is_datetime`). Nil for non-date formats.
    public static func kind(of code: String) -> Kind? {
        guard isDateFormat(code) else { return nil }
        let hasDate = code.contains { "dy".contains($0) }, hasTime = code.contains { "hs".contains($0) }
        if hasDate && hasTime { return .datetime }
        return hasDate ? .date : .time
    }

    /// True when the format scales by 100 (a `%` outside quoted literals).
    public static func isPercentFormat(_ code: String) -> Bool { stripLiterals(code).contains("%") }
}

/// The complete formatting of a cell (openpyxl's StyleArray resolved into objects).
public struct CellStyle: Hashable, Sendable {
    public var font = Font.default
    public var fill = PatternFill.none
    public var border = Border.none
    public var alignment = Alignment.none
    public var protection = Protection()
    public var numberFormat = NumberFormat.general
    /// The `Workbook.namedStyles` entry this cell is linked to ("Title", "Heading 1", one of your own); nil is
    /// "Normal", the way openpyxl's `cell.style` reads "Normal" when nothing was assigned.
    ///
    /// The link is *not* what makes the cell look the way it does — the fields above already hold the effective
    /// formatting, exactly as the file's `cellXf` does. Changing a named style therefore does not restyle the cells
    /// that point at it; the link is there so that Excel still shows the style as applied, and so that a round trip
    /// does not quietly break it.
    public var namedStyle: String?
    public init() {}
    public static let `default` = CellStyle()
}

/// A named cell style: the `cellStyles` / `cellStyleXfs` pair of styles.xml, and openpyxl's `NamedStyle`. Every
/// workbook has at least "Normal"; Excel ships "Title", "Heading 1"… and a file may add its own.
public struct NamedStyle: Hashable, Sendable {
    public var name: String
    /// The formatting the style itself carries. A cell linked to it keeps its own resolved `CellStyle`.
    public var style: CellStyle
    /// Excel's index into its list of built-in styles (0 = Normal, 15 = Title), when this is one of them.
    public var builtinID: Int?
    /// Hidden styles do not appear in Excel's style gallery.
    public var hidden: Bool

    public init(name: String, style: CellStyle = .default, builtinID: Int? = nil, hidden: Bool = false) {
        self.name = name; self.style = style; self.builtinID = builtinID; self.hidden = hidden
    }

    /// The one style every workbook has.
    public static let normal = NamedStyle(name: "Normal", builtinID: 0)

    /// What a cell looks like once this style is applied to it — the style's own formatting plus the link back to
    /// it. openpyxl spells the same thing `cell.style = "Title"`:
    ///
    ///     sheet[cell: "A1"].style = heading.applied
    ///     sheet.style("A1:D1") { $0 = heading.applied }
    public var applied: CellStyle {
        var s = style
        s.namedStyle = name
        return s
    }
}
