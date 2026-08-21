import Foundation

/// A calendar date with no time zone (what a spreadsheet date cell actually stores).
/// Arithmetic is integer-based (proleptic Gregorian), so results never depend on the host time zone.
public struct CivilDate: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), day >= 1, day <= CivilDate.daysIn(month: month, year: year) else { return nil }
        self.year = year; self.month = month; self.day = day
    }

    /// Days since 1970-01-01 → date.
    public init(dayNumber: Int) {
        let (y, m, d) = CivilDate.civilFromDays(dayNumber)
        self.year = y; self.month = m; self.day = d
    }

    /// Strict `YYYY-MM-DD`.
    public init?(iso: String) {
        let p = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// Days since 1970-01-01.
    public var dayNumber: Int { CivilDate.daysFromCivil(year, month, day) }
    /// ISO weekday: 1 = Monday … 7 = Sunday.
    public var isoWeekday: Int { ((((dayNumber % 7) + 7) % 7 + 3) % 7) + 1 }
    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public func adding(days: Int) -> CivilDate { CivilDate(dayNumber: dayNumber + days) }
    public static func < (a: CivilDate, b: CivilDate) -> Bool { a.dayNumber < b.dayNumber }

    /// Midnight of this date in the given time zone.
    public func date(in timeZone: TimeZone = .current) -> Date {
        var c = DateComponents(); c.year = year; c.month = month; c.day = day
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        return cal.date(from: c)!
    }

    public init(_ date: Date, in timeZone: TimeZone = .current) {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)!
    }

    public static func isLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }
    public static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeap(year) ? 29 : 28
        default: return 0
        }
    }

    // Howard Hinnant's civil ↔ days algorithms (public domain).
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
    static func civilFromDays(_ z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }
}

/// A time of day with no time zone (a date cell whose serial is < 1, or the fractional part of a datetime).
public struct TimeOfDay: Hashable, Sendable, CustomStringConvertible, Codable {
    public var hour: Int, minute: Int, second: Int, nanosecond: Int
    public init(hour: Int, minute: Int, second: Int = 0, nanosecond: Int = 0) {
        self.hour = hour; self.minute = minute; self.second = second; self.nanosecond = nanosecond
    }
    public var description: String { String(format: "%02d:%02d:%02d", hour, minute, second) }
    /// Fraction of a day.
    public var dayFraction: Double { (Double(hour) * 3600 + Double(minute) * 60 + Double(second) + Double(nanosecond) / 1e9) / 86400 }
    public init(dayFraction f: Double) {
        let total = (f * 86400).rounded(.toNearestOrEven)
        var secs = Int(total)
        let nanos = Int(((total - Double(secs)) * 1e9).rounded())
        hour = secs / 3600; secs %= 3600; minute = secs / 60; second = secs % 60; nanosecond = nanos
    }
}

/// A naive date + time (openpyxl's `datetime`).
public struct CivilDateTime: Hashable, Sendable, CustomStringConvertible, Codable {
    public var date: CivilDate
    public var time: TimeOfDay
    public init(date: CivilDate, time: TimeOfDay = TimeOfDay(hour: 0, minute: 0)) { self.date = date; self.time = time }
    public var description: String { "\(date) \(time)" }
    public var isMidnight: Bool { time.hour == 0 && time.minute == 0 && time.second == 0 && time.nanosecond == 0 }
}

/// Which day serial 0 means. Windows workbooks use 1900 (with Lotus's phantom 1900-02-29); Mac legacy uses 1904.
public enum DateEpoch: Sendable, Hashable {
    case windows1900
    case mac1904
}

/// Excel date serials ⇄ civil dates. Mirrors openpyxl.utils.datetime (from_excel / to_excel).
public enum ExcelDate {
    static let epoch1899_12_30 = CivilDate(year: 1899, month: 12, day: 30)!.dayNumber
    static let epoch1899_12_31 = CivilDate(year: 1899, month: 12, day: 31)!.dayNumber
    static let epoch1904 = CivilDate(year: 1904, month: 1, day: 1)!.dayNumber

    /// Serial → date-time. Serials in [0, 1) are a time of day (`.time`), as in openpyxl.
    public static func fromSerial(_ serial: Double, epoch: DateEpoch = .windows1900) -> CellValue? {
        guard serial.isFinite, serial >= 0 else { return nil }
        let whole = Int(serial.rounded(.down))
        let frac = serial - Double(whole)
        if whole == 0 { return .time(TimeOfDay(dayFraction: frac)) }
        let date: CivilDate
        switch epoch {
        case .mac1904: date = CivilDate(dayNumber: epoch1904 + whole)
        case .windows1900:
            if whole == 60 { date = CivilDate(year: 1900, month: 2, day: 28)! }
            else if whole < 60 { date = CivilDate(dayNumber: epoch1899_12_31 + whole) }
            else { date = CivilDate(dayNumber: epoch1899_12_30 + whole) }
        }
        return .date(CivilDateTime(date: date, time: TimeOfDay(dayFraction: frac)))
    }

    public static func toSerial(_ value: CivilDateTime, epoch: DateEpoch = .windows1900) -> Double {
        let day = value.date.dayNumber
        let whole: Int
        switch epoch {
        case .mac1904: whole = day - epoch1904
        case .windows1900:
            let n = day - epoch1899_12_30
            whole = n < 61 ? n - 1 : n   // before the phantom 1900-02-29
        }
        return Double(whole) + value.time.dayFraction
    }

    public static func toSerial(_ date: CivilDate, epoch: DateEpoch = .windows1900) -> Int {
        Int(toSerial(CivilDateTime(date: date), epoch: epoch))
    }
}
