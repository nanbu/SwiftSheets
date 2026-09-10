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
    public init?(iso8601 iso: String) {
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
    /// From a fraction of a day, rounded to the millisecond as openpyxl's `from_excel` does. Fractions ≥ 1 wrap.
    public init(dayFraction f: Double) {
        var ms = Int((f * 86_400_000).rounded())
        ms = ((ms % 86_400_000) + 86_400_000) % 86_400_000
        self.init(millisecondsSinceMidnight: ms)
    }
    init(millisecondsSinceMidnight ms: Int) {
        hour = ms / 3_600_000; minute = ms / 60_000 % 60; second = ms / 1000 % 60; nanosecond = ms % 1000 * 1_000_000
    }
    /// Parses "12:19", "12:19:01", "12:19:01.123" (ISO 8601 times, ≤ 3 fractional digits as openpyxl accepts).
    public init?(iso8601 iso: String) {
        let p = iso.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(p.count), p[0].count == 2, p[1].count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return nil }
        var sec = 0, nanos = 0
        if p.count == 3 {
            let sp = p[2].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard sp[0].count == 2, let sv = Int(sp[0]) else { return nil }
            sec = sv
            if sp.count == 2 { guard (1...3).contains(sp[1].count), let frac = Int(sp[1]) else { return nil }; nanos = frac * Int(pow(10.0, Double(9 - sp[1].count))) }
            else if sp.count > 2 { return nil }
        }
        guard (0...23).contains(h), (0...59).contains(m), (0...59).contains(sec) else { return nil }
        self.init(hour: h, minute: m, second: sec, nanosecond: nanos)
    }
    /// "14:15:20" or "14:15:20.123" when there is a sub-second part (openpyxl `to_ISO8601` for times).
    public var iso8601: String {
        nanosecond == 0 ? description : description + String(format: ".%03d", nanosecond / 1_000_000)
    }
}

/// A naive date + time (openpyxl's `datetime`).
public struct CivilDateTime: Hashable, Sendable, CustomStringConvertible, Codable {
    public var date: CivilDate
    public var time: TimeOfDay
    public init(date: CivilDate, time: TimeOfDay = TimeOfDay(hour: 0, minute: 0)) { self.date = date; self.time = time }
    public var description: String { "\(date) \(time)" }
    public var isMidnight: Bool { time.hour == 0 && time.minute == 0 && time.second == 0 && time.nanosecond == 0 }
    /// "2013-07-15T06:52:33" (milliseconds appended when present) — openpyxl `to_ISO8601`.
    public var iso8601: String { "\(date)T\(time.iso8601)" }
    /// Parses "2011-06-30T13:35:26Z", "2013-03-04T12:19:01.00Z", "2020-12-03T12:19:01.3" (openpyxl `from_ISO8601`).
    public init?(iso8601 iso: String) {
        var s = iso
        if s.hasSuffix("Z") { s.removeLast() }
        guard let t = s.firstIndex(of: "T") else { return nil }
        guard let d = CivilDate(iso8601: String(s[..<t])), let tm = TimeOfDay(iso8601: String(s[s.index(after: t)...])) else { return nil }
        self.init(date: d, time: tm)
    }
}

/// Which day serial 0 means. Windows workbooks use 1900 (with Lotus's phantom 1900-02-29); Mac legacy uses 1904;
/// OpenDocument lets the origin be any date (`table:null-date`), which `DateEpoch(origin:)` carries as read.
/// A struct with static members rather than an enum, so `wb.epoch = .mac1904` and `wb.epoch == .mac1904` read
/// as before while any origin fits (spec Appendix B.69). Excel and Numbers know only the two named origins:
/// their writers re-base another origin onto 1900 and say so.
public struct DateEpoch: Sendable, Hashable {
    /// The day serial 0 stands for.
    public let origin: CivilDate
    public init(origin: CivilDate) { self.origin = origin }
    /// Serial 0 is 1899-12-30, and serials 1…59 skip the phantom 1900-02-29 — the Windows Excel system.
    public static let windows1900 = DateEpoch(origin: CivilDate(year: 1899, month: 12, day: 30)!)
    /// Serial 0 is 1904-01-01 — the legacy Mac Excel system.
    public static let mac1904 = DateEpoch(origin: CivilDate(year: 1904, month: 1, day: 1)!)
    /// Whether this is one of the two origins Excel's file format can name.
    public var isExcelOrigin: Bool { self == .windows1900 || self == .mac1904 }
}

extension DateEpoch {
    /// The day number (`CivilDate.dayNumber`) that serial 0 stands for.
    package var baseDayNumber: Int { origin.dayNumber }
    /// Whether serials 1…59 skip Lotus's phantom 1900-02-29 (only the Windows 1900 system does).
    package var hasPhantomLeapDay: Bool { self == .windows1900 }
}

// Excel date serials ⇄ civil dates, on the types themselves (spec Appendix B.66). Mirrors openpyxl.utils.datetime
// (`from_excel` / `to_excel`): serials may be negative, fractions are rounded to the millisecond, and the 1900 epoch
// skips Lotus's phantom 1900-02-29.
extension CellValue {
    /// A serial as `.date` / `.time`. Serials in [0, 1) are a time of day, as in openpyxl. Nil for NaN / infinities.
    public init?(serial: Double, epoch: DateEpoch = .windows1900) {
        guard serial.isFinite else { return nil }
        var day = Int(serial.rounded(.down))
        let fraction = serial - Double(day)
        let ms = Int((fraction * 86_400_000).rounded())
        let diffDays = ms / 86_400_000, rest = ms % 86_400_000
        if serial >= 0, serial < 1, diffDays == 0 { self = .time(TimeOfDay(millisecondsSinceMidnight: rest)); return }
        if serial > 0, serial < 60, epoch.hasPhantomLeapDay { day += 1 }
        self = .date(CivilDateTime(date: CivilDate(dayNumber: epoch.baseDayNumber + day + diffDays), time: TimeOfDay(millisecondsSinceMidnight: rest)))
    }

    /// The serial of a date-like value (`.date`, `.time`, `.duration`); nil for the other cases.
    public func serial(epoch: DateEpoch = .windows1900) -> Double? {
        switch self {
        case .date(let dt): return dt.serial(epoch: epoch)
        case .time(let t): return t.dayFraction
        case .duration(let d): return d.serialDays
        default: return nil
        }
    }

    /// ISO 8601 text as `.date` / `.time` / `.duration` (openpyxl `from_ISO8601`): dates, times, datetimes and
    /// `PT2H0M1S` durations. Nil for anything else.
    public init?(iso8601 text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let dt = CivilDateTime(iso8601: s) { self = .date(dt); return }
        if let d = CivilDate(iso8601: s.hasSuffix("Z") ? String(s.dropLast()) : s) { self = .date(CivilDateTime(date: d)); return }
        if let t = TimeOfDay(iso8601: s.hasSuffix("Z") ? String(s.dropLast()) : s) { self = .time(t); return }
        if s.hasPrefix("PT") {
            var total = 0.0, number = "", matched = false
            for ch in s.dropFirst(2) {
                if ch.isNumber || ch == "." { number.append(ch); continue }
                guard let n = Double(number) else { return nil }
                switch ch { case "H": total += n * 3600; case "M": total += n * 60; case "S": total += n; default: return nil }
                number = ""; matched = true
            }
            guard matched, number.isEmpty else { return nil }
            self = .duration(.milliseconds(Int64((total * 1000).rounded()))); return
        }
        return nil
    }

    /// `.date` as "2011-12-25T14:23:55" (date-only when midnight), `.time` as "14:15:25" (openpyxl `to_ISO8601`);
    /// nil for the other cases.
    public var iso8601: String? {
        switch self {
        case .date(let dt): return dt.isMidnight ? dt.date.description : dt.iso8601
        case .time(let t): return t.iso8601
        default: return nil
        }
    }
}

extension CivilDateTime {
    /// The Excel serial: whole days from the epoch plus the day fraction.
    public func serial(epoch: DateEpoch = .windows1900) -> Double {
        let day = date.dayNumber
        var whole = day - epoch.baseDayNumber
        if epoch.hasPhantomLeapDay, whole > 0, whole <= 60 { whole -= 1 }   // before the phantom 1900-02-29
        return Double(whole) + time.dayFraction
    }
}

extension CivilDate {
    /// The Excel serial of midnight on this day.
    public func serial(epoch: DateEpoch = .windows1900) -> Int {
        Int(CivilDateTime(date: self).serial(epoch: epoch))
    }
}

extension Duration {
    /// Elapsed time from a serial measured in days (openpyxl `from_excel(value, timedelta=True)`), rounded to the
    /// millisecond. Nil for NaN / infinities.
    public init?(serialDays: Double) {
        guard serialDays.isFinite else { return nil }
        self = .milliseconds(Int64((serialDays * 86_400_000).rounded()))
    }

    /// Elapsed time in days, the way a duration cell is stored (openpyxl `timedelta_to_days`).
    public var serialDays: Double {
        let (s, attos) = components
        return (Double(s) + Double(attos) / 1e18) / 86_400
    }
}
