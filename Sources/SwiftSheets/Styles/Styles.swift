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

    public enum Underline: String, Sendable { case single, double, singleAccounting, doubleAccounting }

    public init(name: String? = nil, size: Double? = nil, bold: Bool = false, italic: Bool = false, underline: Underline? = nil,
                strikethrough: Bool = false, color: Color? = nil) {
        self.name = name; self.size = size; self.bold = bold; self.italic = italic; self.underline = underline
        self.strikethrough = strikethrough; self.color = color
    }

    /// The default font Excel assumes when none is set (openpyxl's DEFAULT_FONT).
    public static let `default` = Font(name: "Calibri", size: 11, color: .theme(1))
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
    public init(left: Side = Side(), right: Side = Side(), top: Side = Side(), bottom: Side = Side(), diagonal: Side = Side()) {
        self.left = left; self.right = right; self.top = top; self.bottom = bottom; self.diagonal = diagonal
    }
    /// The same side on all four edges.
    public static func all(_ side: Side) -> Border { Border(left: side, right: side, top: side, bottom: side) }
    public static let none = Border()
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
    public static let dateYYYYMMDD = "yyyy-mm-dd"
    public static let percentage = "0%"

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
    static let builtinIDs: [String: Int] = Dictionary(builtin.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

    /// True when the code formats a date or time (openpyxl.styles.numbers.is_date_format).
    public static func isDateFormat(_ code: String) -> Bool {
        let first = code.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init) ?? code
        let stripped = stripLiterals(first)
        return stripped.range(of: "[dmyhsDMYHS]", options: .regularExpression) != nil && !stripped.contains("@")
    }

    /// True when the format scales by 100 (a `%` outside quoted literals).
    public static func isPercentFormat(_ code: String) -> Bool { stripLiterals(code).contains("%") }

    static func stripLiterals(_ code: String) -> String {
        var out = "", inQuote = false, inBracket = false, escape = false
        for ch in code {
            if escape { escape = false; continue }
            if inQuote { if ch == "\"" { inQuote = false }; continue }
            if inBracket { if ch == "]" { inBracket = false }; continue }
            switch ch {
            case "\"": inQuote = true
            case "[": inBracket = true
            case "\\", "_", "*": escape = true
            default: out.append(ch)
            }
        }
        return out
    }
}

/// The complete formatting of a cell (openpyxl's StyleArray resolved into objects).
public struct CellStyle: Hashable, Sendable {
    public var font = Font.default
    public var fill = PatternFill.none
    public var border = Border.none
    public var alignment = Alignment.none
    public var protection = Protection()
    public var numberFormat = NumberFormat.general
    public init() {}
    public static let `default` = CellStyle()
}
