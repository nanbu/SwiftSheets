import Foundation

/// What a cell holds. Mirrors the types openpyxl hands back: `int` / `float` / `str` / `bool` / `datetime` /
/// `time` / formula text / error — plus rich text, which openpyxl only exposes when asked.
public enum CellValue: Hashable, Sendable {
    case integer(Int)
    case number(Double)
    case string(String)
    case bool(Bool)
    case date(CivilDateTime)
    case time(TimeOfDay)
    /// A formula such as "=SUM(A1:A3)". `cached` is the last value Excel computed (what `dataOnly` readers return).
    case formula(String, cached: CellValueBox?)
    case error(String)
    case richText([TextRun])

    public var stringValue: String? { if case .string(let s) = self { return s }; if case .richText(let r) = self { return r.map(\.text).joined() }; return nil }
    public var intValue: Int? { switch self { case .integer(let i): return i; case .number(let d) where d == d.rounded(): return Int(d); default: return nil } }
    public var doubleValue: Double? { switch self { case .integer(let i): return Double(i); case .number(let d): return d; default: return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var dateValue: CivilDateTime? { if case .date(let d) = self { return d }; return nil }

    /// Python-style `str(value)` — useful when porting openpyxl code that stringifies cells.
    public var pythonString: String {
        switch self {
        case .integer(let i): return String(i)
        case .number(let d): return d == d.rounded() && abs(d) < 1e16 ? String(format: "%.1f", d) : "\(d)"
        case .string(let s): return s
        case .bool(let b): return b ? "True" : "False"
        case .date(let d): return d.isMidnight ? "\(d.date) 00:00:00" : d.description
        case .time(let t): return t.description
        case .formula(let f, _): return f
        case .error(let e): return e
        case .richText(let runs): return runs.map(\.text).joined()
        }
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
    public init(stringLiteral v: String) { self = v.hasPrefix("=") ? .formula(v, cached: nil) : .string(v) }
    public init(integerLiteral v: Int) { self = .integer(v) }
    public init(floatLiteral v: Double) { self = .number(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
}

extension CellValue {
    public init(_ date: CivilDate) { self = .date(CivilDateTime(date: date)) }
    public init(_ dt: CivilDateTime) { self = .date(dt) }
}
