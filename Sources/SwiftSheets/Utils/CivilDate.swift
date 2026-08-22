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
    public init?(iso: String) {
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
    public init?(iso: String) {
        var s = iso
        if s.hasSuffix("Z") { s.removeLast() }
        guard let t = s.firstIndex(of: "T") else { return nil }
        guard let d = CivilDate(iso: String(s[..<t])), let tm = TimeOfDay(iso: String(s[s.index(after: t)...])) else { return nil }
        self.init(date: d, time: tm)
    }
}

/// Which day serial 0 means. Windows workbooks use 1900 (with Lotus's phantom 1900-02-29); Mac legacy uses 1904.
public enum DateEpoch: Sendable, Hashable {
    case windows1900
    case mac1904
}

/// Excel date serials ⇄ civil dates. Mirrors openpyxl.utils.datetime (`from_excel` / `to_excel`): serials may be
/// negative, fractions are rounded to the millisecond, and the 1900 epoch skips Lotus's phantom 1900-02-29.
public enum ExcelDate {
    static let epoch1899_12_30 = CivilDate(year: 1899, month: 12, day: 30)!.dayNumber
    static let epoch1904 = CivilDate(year: 1904, month: 1, day: 1)!.dayNumber

    /// Serial → `.date` / `.time`. Serials in [0, 1) are a time of day, as in openpyxl. Nil for NaN / infinities.
    public static func fromSerial(_ serial: Double, epoch: DateEpoch = .windows1900) -> CellValue? {
        guard serial.isFinite else { return nil }
        var day = Int(serial.rounded(.down))
        let fraction = serial - Double(day)
        let ms = Int((fraction * 86_400_000).rounded())
        let diffDays = ms / 86_400_000, rest = ms % 86_400_000
        if serial >= 0, serial < 1, diffDays == 0 { return .time(TimeOfDay(millisecondsSinceMidnight: rest)) }
        if serial > 0, serial < 60, epoch == .windows1900 { day += 1 }
        let base = epoch == .mac1904 ? epoch1904 : epoch1899_12_30
        return .date(CivilDateTime(date: CivilDate(dayNumber: base + day + diffDays), time: TimeOfDay(millisecondsSinceMidnight: rest)))
    }

    /// Serial → elapsed time (openpyxl `from_excel(value, timedelta=True)`), rounded to the millisecond. Nil for NaN.
    public static func durationFromSerial(_ serial: Double) -> Duration? {
        guard serial.isFinite else { return nil }
        let ms = (serial * 86_400_000).rounded()
        return .milliseconds(Int64(ms))
    }

    public static func toSerial(_ value: CivilDateTime, epoch: DateEpoch = .windows1900) -> Double {
        let day = value.date.dayNumber
        var whole: Int
        switch epoch {
        case .mac1904: whole = day - epoch1904
        case .windows1900:
            whole = day - epoch1899_12_30
            if whole > 0, whole <= 60 { whole -= 1 }   // before the phantom 1900-02-29
        }
        return Double(whole) + value.time.dayFraction
    }

    public static func toSerial(_ date: CivilDate, epoch: DateEpoch = .windows1900) -> Int {
        Int(toSerial(CivilDateTime(date: date), epoch: epoch))
    }

    /// Elapsed time → days (openpyxl `timedelta_to_days`).
    public static func toSerial(_ duration: Duration) -> Double {
        let (s, attos) = duration.components
        return (Double(s) + Double(attos) / 1e18) / 86_400
    }

    /// Serial for any date-like value; nil for other cases.
    public static func toSerial(_ value: CellValue, epoch: DateEpoch = .windows1900) -> Double? {
        switch value {
        case .date(let dt): return toSerial(dt, epoch: epoch)
        case .time(let t): return t.dayFraction
        case .duration(let d): return toSerial(d)
        default: return nil
        }
    }

    /// ISO 8601 text → `.date` / `.time` / `.duration` (openpyxl `from_ISO8601`): dates, times, datetimes and `PT2H0M1S` durations.
    public static func fromISO8601(_ text: String) -> CellValue? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let dt = CivilDateTime(iso: s) { return .date(dt) }
        if let d = CivilDate(iso: s.hasSuffix("Z") ? String(s.dropLast()) : s) { return .date(CivilDateTime(date: d)) }
        if let t = TimeOfDay(iso: s.hasSuffix("Z") ? String(s.dropLast()) : s) { return .time(t) }
        if s.hasPrefix("PT") {
            var total = 0.0, number = "", matched = false
            for ch in s.dropFirst(2) {
                if ch.isNumber || ch == "." { number.append(ch); continue }
                guard let n = Double(number) else { return nil }
                switch ch { case "H": total += n * 3600; case "M": total += n * 60; case "S": total += n; default: return nil }
                number = ""; matched = true
            }
            guard matched, number.isEmpty else { return nil }
            return .duration(.milliseconds(Int64((total * 1000).rounded())))
        }
        return nil
    }

    /// `.date` → "2011-12-25T14:23:55" (date-only when midnight), `.time` → "14:15:25" (openpyxl `to_ISO8601`).
    public static func toISO8601(_ value: CellValue) -> String? {
        switch value {
        case .date(let dt): return dt.isMidnight ? dt.date.description : dt.iso8601
        case .time(let t): return t.iso8601
        default: return nil
        }
    }
}
