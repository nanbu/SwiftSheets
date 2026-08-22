import Foundation

/// What a cell holds. Mirrors the types openpyxl hands back: `int` / `float` / `str` / `bool` / `datetime` /
/// `time` / `timedelta` / formula text / error — plus rich text, which openpyxl only exposes when asked.
public enum CellValue: Hashable, Sendable {
    case integer(Int)
    case number(Double)
    case string(String)
    case bool(Bool)
    case date(CivilDateTime)
    case time(TimeOfDay)
    /// Elapsed time (openpyxl `timedelta`): what a cell with an `[h]:mm:ss`-style format holds.
    case duration(Duration)
    /// A formula such as "=SUM(A1:A3)". `cached` is the last value Excel computed (what `dataOnly` readers return).
    case formula(String, cached: CellValueBox?)
    case error(String)
    case richText([TextRun])

    /// Excel's error literals (openpyxl ERROR_CODES). A string literal equal to one of these becomes `.error`.
    public static let errorCodes: Set<String> = ["#NULL!", "#DIV/0!", "#VALUE!", "#REF!", "#NAME?", "#NUM!", "#N/A"]

    public var stringValue: String? { if case .string(let s) = self { return s }; if case .richText(let r) = self { return r.map(\.text).joined() }; return nil }
    public var intValue: Int? { switch self { case .integer(let i): return i; case .number(let d) where d == d.rounded(): return Int(d); default: return nil } }
    public var doubleValue: Double? { switch self { case .integer(let i): return Double(i); case .number(let d): return d; default: return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var dateValue: CivilDateTime? { if case .date(let d) = self { return d }; return nil }
    public var durationValue: Duration? { if case .duration(let d) = self { return d }; return nil }

    /// openpyxl's `cell.data_type` letter: n (numeric / empty), s (string), b, d (date-like), f (formula), e (error).
    public var dataType: Character {
        switch self {
        case .integer, .number: return "n"
        case .string, .richText: return "s"
        case .bool: return "b"
        case .date, .time, .duration: return "d"
        case .formula: return "f"
        case .error: return "e"
        }
    }

    /// Python-style `str(value)` — useful when porting openpyxl code that stringifies cells.
    public var pythonString: String {
        switch self {
        case .integer(let i): return String(i)
        case .number(let d): return d == d.rounded() && abs(d) < 1e16 ? String(format: "%.1f", d) : "\(d)"
        case .string(let s): return s
        case .bool(let b): return b ? "True" : "False"
        case .date(let d): return d.isMidnight ? "\(d.date) 00:00:00" : d.description
        case .time(let t): return t.description
        case .duration(let d):
            let (secs, attos) = d.components
            let total = Double(secs) + Double(attos) / 1e18
            let days = Int((total / 86400).rounded(.down)), rest = total - Double(days) * 86400
            let h = Int(rest) / 3600, m = Int(rest) / 60 % 60, sec = rest - Double(Int(rest) / 60 * 60)
            let secText = sec == sec.rounded() ? String(format: "%02d", Int(sec)) : String(format: "%09.6f", sec)
            return days == 0 ? "\(h):\(String(format: "%02d", m)):\(secText)" : "\(days) day\(days == 1 ? "" : "s"), \(h):\(String(format: "%02d", m)):\(secText)"
        case .formula(let f, _): return f
        case .error(let e): return e
        case .richText(let runs): return runs.map(\.text).joined()
        }
    }

    /// The control characters OOXML forbids in cell text: U+0000–U+0008, U+000B–U+000C, U+000E–U+001F (openpyxl
    /// raises `IllegalCharacterError`; SwiftSheets drops them when writing).
    public static func containsIllegalCharacters(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value < 0x20 && $0 != "\t" && $0 != "\n" && $0 != "\r" }
    }
}

/// Indirection so `CellValue.formula` can carry a cached `CellValue`.
public final class CellValueBox: Hashable, Sendable {
    public let value: CellValue
    public init(_ value: CellValue) { self.value = value }
    public static func == (a: CellValueBox, b: CellValueBox) -> Bool { a.value == b.value }
    public func hash(into h: inout Hasher) { h.combine(value) }
}

/// One run of a rich-text string.
public struct TextRun: Hashable, Sendable {
    public var text: String
    public var font: Font?
    public init(_ text: String, font: Font? = nil) { self.text = text; self.font = font }
}

extension CellValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    /// Infers like openpyxl's `_bind_value`: "=…" (more than the bare "=") is a formula, an error code is `.error`, else text.
    public init(stringLiteral v: String) { self.init(inferring: v) }
    /// Same inference for a runtime `String`.
    public init(inferring v: String) {
        if v.count > 1, v.hasPrefix("=") { self = .formula(v, cached: nil) }
        else if CellValue.errorCodes.contains(v) { self = .error(v) }
        else { self = .string(v) }
    }
    public init(integerLiteral v: Int) { self = .integer(v) }
    public init(floatLiteral v: Double) { self = .number(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
}

extension CellValue {
    public init(_ date: CivilDate) { self = .date(CivilDateTime(date: date)) }
    public init(_ dt: CivilDateTime) { self = .date(dt) }
    public init(_ time: TimeOfDay) { self = .time(time) }
    public init(_ duration: Duration) { self = .duration(duration) }
}
