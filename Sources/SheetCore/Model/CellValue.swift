import Foundation

/// What a cell holds — the *meaning* of a value, never its file representation (no shared-string indices, no serial
/// dates). Numbers keep the int / float distinction openpyxl makes (`integer` vs `number`); `number` is a `Decimal`
/// so digits survive round trips and Numbers' decimal128 fits later.
public indirect enum CellValue: Hashable, Sendable {
    case text(String)
    case integer(Int)
    case number(Decimal)
    case bool(Bool)
    /// A calendar date (+ time) with no time zone.
    case date(CivilDateTime)
    case time(TimeOfDay)
    /// Elapsed time (openpyxl `timedelta`): what a cell with an `[h]:mm:ss`-style format holds.
    case duration(Duration)
    /// A parsed formula plus the last value the producing application computed (what `dataOnly` readers return).
    case formula(FormulaExpr, cached: CellValue?)
    /// "#N/A", "#REF!" and friends.
    case error(String)
    case richText([TextRun])

    /// Excel's error literals. A string literal equal to one of these becomes `.error`.
    public static let errorCodes: Set<String> = ["#NULL!", "#DIV/0!", "#VALUE!", "#REF!", "#NAME?", "#NUM!", "#N/A"]

    // MARK: - Typed accessors

    /// The text of a text / rich-text cell; nil for other kinds.
    public var textValue: String? {
        switch self { case .text(let s): s; case .richText(let r): r.map(\.text).joined(); default: nil }
    }
    /// Any value as display text (numbers, dates and booleans are stringified; formulas render in XLSX dialect).
    public var stringValue: String { pythonString }
    /// The numeric value of an `integer` / `number` cell (or of a formula's cached number).
    public var numberValue: Decimal? {
        switch self { case .integer(let i): Decimal(i); case .number(let d): d; case .formula(_, let c): c?.numberValue; default: nil }
    }
    public var doubleValue: Double? {
        switch self {
        case .integer(let i): return Double(i)
        case .number(let d): return Double("\(d)") ?? NSDecimalNumber(decimal: d).doubleValue   // the text is exact; NSDecimalNumber's conversion is not
        case .formula(_, let c): return c?.doubleValue
        default: return nil
        }
    }
    /// The value as an `Int` when it is integral.
    public var intValue: Int? {
        switch self {
        case .integer(let i): return i
        case .number(let d): return Int("\(d)")
        case .formula(_, let c): return c?.intValue
        default: return nil
        }
    }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; if case .formula(_, let c) = self { return c?.boolValue }; return nil }
    public var dateValue: CivilDateTime? { if case .date(let d) = self { return d }; if case .formula(_, let c) = self { return c?.dateValue }; return nil }
    public var timeValue: TimeOfDay? { if case .time(let t) = self { return t }; return nil }
    public var durationValue: Duration? { if case .duration(let d) = self { return d }; return nil }
    public var errorValue: String? { if case .error(let e) = self { return e }; return nil }
    /// The AST of a formula cell.
    public var formula: FormulaExpr? { if case .formula(let f, _) = self { return f }; return nil }
    /// For a formula cell its cached value; for anything else the value itself.
    public var cachedValue: CellValue? { if case .formula(_, let c) = self { return c }; return self }

    public var isNumeric: Bool { if case .integer = self { return true }; if case .number = self { return true }; return false }

    /// openpyxl's `cell.data_type` letter: n (numeric / empty), s (string), b, d (date-like), f (formula), e (error).
    public var dataType: Character {
        switch self {
        case .integer, .number: return "n"
        case .text, .richText: return "s"
        case .bool: return "b"
        case .date, .time, .duration: return "d"
        case .formula: return "f"
        case .error: return "e"
        }
    }

    /// Python-style `str(value)` — what openpyxl-based code sees when it stringifies a cell.
    public var pythonString: String {
        switch self {
        case .integer(let i): return String(i)
        case .number(let dec):
            let d = Double("\(dec)") ?? NSDecimalNumber(decimal: dec).doubleValue
            return d == d.rounded() && abs(d) < 1e16 ? String(format: "%.1f", d) : "\(d)"
        case .text(let s): return s
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
        case .formula(let f, _): return "=" + f.rendered(as: .xlsx)
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

/// One run of a rich-text string.
public struct TextRun: Hashable, Sendable {
    public var text: String
    public var font: Font?
    public init(_ text: String, font: Font? = nil) { self.text = text; self.font = font }
}

// MARK: - Literal and value conversions

extension CellValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    /// Infers like openpyxl's `_bind_value`: "=…" (more than the bare "=") is a formula, an error code is `.error`, else text.
    public init(stringLiteral v: String) { self.init(inferring: v) }
    /// Same inference for a runtime `String`.
    public init(inferring v: String) {
        if v.count > 1, v.hasPrefix("=") { self = .formula(FormulaExpr.parse(v, dialect: .xlsx), cached: nil) }
        else if CellValue.errorCodes.contains(v) { self = .error(v) }
        else { self = .text(v) }
    }
    public init(integerLiteral v: Int) { self = .integer(v) }
    /// Goes through the shortest round-trip text of the literal, so `0.07` is exactly 0.07 (not `Decimal(0.07)`'s noise).
    public init(floatLiteral v: Double) { self.init(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
}

extension CellValue {
    public init(_ value: Int) { self = .integer(value) }
    /// A floating-point number, converted through its shortest decimal text (`0.1` stays 0.1). NaN / infinities become `#NUM!`.
    public init(_ value: Double) {
        guard value.isFinite else { self = .error("#NUM!"); return }
        self = .number(Decimal(string: "\(value)") ?? Decimal(value))
    }
    public init(_ value: Decimal) { self = .number(value) }
    public init(_ value: String) { self = .text(value) }
    public init(_ value: Bool) { self = .bool(value) }
    public init(_ date: CivilDate) { self = .date(CivilDateTime(date: date)) }
    public init(_ dt: CivilDateTime) { self = .date(dt) }
    public init(_ time: TimeOfDay) { self = .time(time) }
    public init(_ duration: Duration) { self = .duration(duration) }
    /// A `Foundation.Date` interpreted in `timeZone` (spreadsheet dates have no zone, so one must be chosen).
    public init(_ date: Date, in timeZone: TimeZone = .current) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let civil = CivilDate(year: c.year!, month: c.month!, day: c.day!)!
        self = .date(CivilDateTime(date: civil, time: TimeOfDay(hour: c.hour!, minute: c.minute!, second: c.second!, nanosecond: c.nanosecond!)))
    }
    /// A formula from its text ("=SUM(A1:B2)", leading "=" optional). Unparsable text is kept verbatim as `.unparsed`.
    public init(formula text: String, dialect: SheetFormat = .xlsx, cached: CellValue? = nil) {
        self = .formula(FormulaExpr.parse(text, dialect: dialect), cached: cached)
    }
}

/// `sheet["C1"] = Formula("=SUM(A1:B2)")` — a formula value from its text (parsed on the spot, `.unparsed` when the
/// parser cannot read it).
public func Formula(_ text: String, dialect: SheetFormat = .xlsx) -> CellValue { CellValue(formula: text, dialect: dialect) }
