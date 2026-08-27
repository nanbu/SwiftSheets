import Foundation
import SheetCore

/// Delimited text (.csv / .tsv) — spec §9. RFC 4180 quoting plus the real-world dialects Excel and friends produce:
/// `,` / `;` / tab sniffed from the first line, `sep=;` headers, mixed line endings, explicit legacy encodings.
///
/// Reading is type-neutral by default (every field is text, so "01234" keeps its zero); `CSVReadOptions.inferTypes`
/// turns on number / bool / date inference. Writing renders one sheet; everything CSV cannot hold (other sheets,
/// formatting, formula structure) is reported as `ConversionWarning`s on the `WriteResult`, never lost silently.
public enum CSVCodec: SpreadsheetCodec {
    public static var format: SheetFormat { .csv }

    /// CSV is not a ZIP container; detection happens in `SheetFormat.detect` via `TextEncodingSniffer`.
    public static func canDecode(_ container: ZipInspection) -> Bool { false }

    /// Reading reports what the decoding had to repair (only with `CSVReadOptions.lossy`: undecodable bytes → U+FFFD).
    public static func read(_ data: Data, options: ReadOptions = ReadOptions()) throws -> ReadResult {
        let (wb, warnings) = try readParsing(data, options: options)
        return ReadResult(workbook: wb, warnings: warnings)
    }

    static func readParsing(_ data: Data, options: ReadOptions = ReadOptions()) throws -> (workbook: Workbook, warnings: [ConversionWarning]) {
        let csv = options.csv
        let (text, warnings) = try decode(data, options: csv)
        var body = Substring(text)
        let delimiter: Character
        if let dialect = csv.dialect {
            delimiter = dialect.delimiter
        } else if let sep = excelSeparatorLine(in: body) {
            delimiter = sep.delimiter
            body = body[sep.bodyStart...]
        } else {
            delimiter = sniffDelimiter(firstLineOf: body, filename: options.filename)
        }
        let quote = csv.dialect?.quote ?? "\""
        let records = parse(body, delimiter: delimiter, quote: quote)

        var sheet = Sheet(name: "Sheet1")
        let inference = csv.inferTypes ? TypeInference(dateFormats: csv.dateFormats) : nil
        for (r, record) in records.enumerated() {
            for (c, field) in record.enumerated() where !field.isEmpty {
                sheet[r, c] = inference?.value(for: field) ?? .text(field)
            }
        }
        sheet.nextAppendRow = records.count

        var wb = Workbook(sheets: [sheet])
        wb.sourceInfo = SourceInfo(format: .csv)
        wb.preserved.sourceFormat = .csv
        return (wb, warnings)
    }

    public static func write(_ workbook: Workbook, options: WriteOptions = WriteOptions()) throws -> WriteResult {
        let csv = options.csv
        guard !workbook.sheets.isEmpty else { throw SheetError.invalidWorkbook("workbook has no sheets") }
        let sheet: Sheet
        if let name = csv.sheet {
            guard let s = workbook.sheets[name] else { throw SheetError.invalidWorkbook("no sheet named \(name)") }
            sheet = s
        } else {
            sheet = workbook.activeSheet
        }

        var warnings: [ConversionWarning] = []
        if workbook.sheets.count > 1 {
            warnings.append(ConversionWarning(.dropped, subject: .sheets, message: "\(workbook.sheets.count - 1) other sheet(s) not written: CSV holds a single sheet"))
        }
        let table = sheet.table
        // CSV is one grid: a canvas carrying several tables (Numbers) keeps only the first one
        if sheet.tables.count > 1 {
            warnings.append(ConversionWarning(.dropped, subject: .tables, sheet: sheet.name,
                                              message: "\(sheet.tables.count - 1) other table(s) not written: CSV holds a single table (write .numbers to keep them)"))
        }
        if !sheet.images.isEmpty {
            warnings.append(ConversionWarning(.dropped, subject: .objects, sheet: sheet.name,
                                              message: "\(sheet.images.count) image(s) not written: CSV holds values only (write .xlsx to keep them)"))
        }
        if !sheet.charts.isEmpty {
            warnings.append(ConversionWarning(.dropped, subject: .objects, sheet: sheet.name,
                                              message: "\(sheet.charts.count) chart(s) not written: CSV holds values only (write .xlsx to keep them)"))
        }
        // a date value's automatic number format is not formatting the user applied — it does not count
        func hasFormatting(_ c: Cell) -> Bool {
            var plain = c.style; plain.numberFormat = CellStyle.default.numberFormat
            if plain != .default { return true }
            if c.style.numberFormat == CellStyle.default.numberFormat { return false }
            return !(c.value?.dataType == "d" && NumberFormat.isDateFormat(c.style.numberFormat))
        }
        if table.cells.values.contains(where: { hasFormatting($0) || $0.value?.formula != nil }) {
            warnings.append(ConversionWarning(.degraded, subject: .formatting, message: "formatting and formula structure are not kept in CSV"))
        }

        let renderer = FieldRenderer(options: csv)
        let delimiter = String(csv.dialect.delimiter)
        var text = ""
        var fields: [(ref: CellRef, text: String)] = []   // non-empty fields, for the encoding check
        if let extent = table.extent {
            for r in 0...extent.maxRow {
                var line: [String] = []
                for c in 0...extent.maxCol {
                    let ref = CellRef(row: r, col: c)
                    guard let value = table.cells[ref]?.value else { line.append(""); continue }
                    let field = renderer.render(value, at: ref, sheet: sheet.name, warnings: &warnings)
                    fields.append((ref, field))
                    line.append(quoted(field, delimiter: csv.dialect.delimiter, quote: csv.dialect.quote))
                }
                text += line.joined(separator: delimiter) + csv.newline.rawValue
            }
        }

        let data = try encode(text, fields: fields, sheet: sheet.name, options: csv, warnings: &warnings)
        return WriteResult(data: data, warnings: warnings, suggestion: WriteResult.suggest(from: warnings, target: .csv, options: options))
    }

    // MARK: - Decoding

    /// Bytes → text honouring the options: BOM sniffing when no encoding is given, a strict UTF-8 / UTF-16 check with
    /// the byte offset of the first bad sequence, U+FFFD repair with `lossy`.
    static func decode(_ data: Data, options: CSVReadOptions) throws -> (String, [ConversionWarning]) {
        var encoding: String.Encoding
        var start = 0
        if let explicit = options.encoding {
            encoding = explicit
            if explicit == .utf8, let (bomEncoding, length) = TextEncodingSniffer.bom(in: data), bomEncoding == .utf8 { start = length }
        } else if let (bomEncoding, length) = TextEncodingSniffer.bom(in: data) {
            encoding = bomEncoding; start = length
        } else {
            encoding = .utf8
        }
        // `.utf16` without a fixed byte order: a BOM decides, else big-endian (what Foundation assumes).
        if encoding == .utf16 {
            if let (bomEncoding, length) = TextEncodingSniffer.bom(in: Data(data.dropFirst(start))), bomEncoding != .utf8 {
                encoding = bomEncoding; start += length
            } else {
                encoding = .utf16BigEndian
            }
        }
        let body = Data(data.dropFirst(start))
        var warnings: [ConversionWarning] = []

        func repairedOrThrow(firstBadOffset: Int, repaired: @autoclosure () -> String, detail: String) throws -> String {
            let offset = start + firstBadOffset
            guard options.lossy else { throw SheetError.malformedPart(path: "offset \(offset)", detail: detail) }
            warnings.append(ConversionWarning(.degraded, message: "undecodable bytes from offset \(offset) replaced with U+FFFD (\(detail))"))
            return repaired()
        }

        switch encoding {
        case .utf8:
            if let bad = firstInvalidUTF8Offset(in: body) {
                return (try repairedOrThrow(firstBadOffset: bad, repaired: String(decoding: body, as: UTF8.self), detail: "invalid UTF-8 sequence"), warnings)
            }
            return (String(decoding: body, as: UTF8.self), warnings)
        case .utf16LittleEndian, .utf16BigEndian:
            let units = utf16Units(of: body, littleEndian: encoding == .utf16LittleEndian)
            if body.count % 2 != 0 {
                return (try repairedOrThrow(firstBadOffset: body.count - 1, repaired: String(decoding: units, as: UTF16.self), detail: "truncated UTF-16 code unit"), warnings)
            }
            if let bad = firstInvalidUTF16Index(in: units) {
                return (try repairedOrThrow(firstBadOffset: bad * 2, repaired: String(decoding: units, as: UTF16.self), detail: "unpaired UTF-16 surrogate"), warnings)
            }
            return (String(decoding: units, as: UTF16.self), warnings)
        default:
            if let text = String(data: body, encoding: encoding) { return (text, warnings) }
            let (repaired, bad) = repairLegacy(body, encoding: encoding)
            let name = String.localizedName(of: encoding)
            return (try repairedOrThrow(firstBadOffset: bad, repaired: repaired, detail: "bytes not valid in \(name)"), warnings)
        }
    }

    /// Byte offset (within `data`) of the first malformed UTF-8 sequence; nil when the whole buffer is valid.
    static func firstInvalidUTF8Offset(in data: Data) -> Int? {
        let bytes = [UInt8](data)
        var i = 0
        let n = bytes.count
        while i < n {
            let b = bytes[i]
            if b < 0x80 { i += 1; continue }
            let length: Int
            var minSecond: UInt8 = 0x80, maxSecond: UInt8 = 0xBF
            switch b {
            case 0xC2...0xDF: length = 2
            case 0xE0: length = 3; minSecond = 0xA0
            case 0xE1...0xEC, 0xEE...0xEF: length = 3
            case 0xED: length = 3; maxSecond = 0x9F          // no surrogates
            case 0xF0: length = 4; minSecond = 0x90
            case 0xF1...0xF3: length = 4
            case 0xF4: length = 4; maxSecond = 0x8F          // ≤ U+10FFFF
            default: return i
            }
            guard i + length <= n else { return i }
            guard bytes[i + 1] >= minSecond, bytes[i + 1] <= maxSecond else { return i }
            for k in 2..<length where bytes[i + k] < 0x80 || bytes[i + k] > 0xBF { return i }
            i += length
        }
        return nil
    }

    static func utf16Units(of data: Data, littleEndian: Bool) -> [UInt16] {
        let bytes = [UInt8](data)
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            let (hi, lo) = littleEndian ? (bytes[i + 1], bytes[i]) : (bytes[i], bytes[i + 1])
            units.append(UInt16(hi) << 8 | UInt16(lo))
            i += 2
        }
        return units
    }

    /// Index of the first unpaired surrogate; nil when every surrogate is properly paired.
    static func firstInvalidUTF16Index(in units: [UInt16]) -> Int? {
        var i = 0
        while i < units.count {
            let u = units[i]
            if UTF16.isLeadSurrogate(u) {
                guard i + 1 < units.count, UTF16.isTrailSurrogate(units[i + 1]) else { return i }
                i += 2
            } else if UTF16.isTrailSurrogate(u) {
                return i
            } else {
                i += 1
            }
        }
        return nil
    }

    /// Decodes a legacy (stateless multi-byte) encoding character by character, replacing undecodable bytes with
    /// U+FFFD. Returns the text and the offset of the first bad byte. Only used after a whole-buffer decode failed.
    static func repairLegacy(_ data: Data, encoding: String.Encoding) -> (String, Int) {
        let bytes = [UInt8](data)
        var out = ""
        var firstBad: Int?
        var i = 0
        scan: while i < bytes.count {
            for length in 1...4 where i + length <= bytes.count {
                if let piece = String(data: Data(bytes[i..<i + length]), encoding: encoding), !piece.isEmpty {
                    out += piece; i += length; continue scan
                }
            }
            if firstBad == nil { firstBad = i }
            out.unicodeScalars.append("\u{FFFD}")
            i += 1
        }
        return (out, firstBad ?? 0)
    }

    // MARK: - Dialect

    /// Excel's `sep=X` first line: the delimiter it declares and where the data starts (past the line terminator).
    static func excelSeparatorLine(in text: Substring) -> (delimiter: Character, bodyStart: Substring.Index)? {
        let lineEnd = text.firstIndex { $0 == "\n" || $0 == "\r" || $0 == "\r\n" } ?? text.endIndex
        let line = text[..<lineEnd]
        guard line.count == 5, line.hasPrefix("sep="), let sep = line.last, sep.unicodeScalars.count == 1 else { return nil }
        var start = lineEnd
        if start < text.endIndex { start = text.index(after: start) }   // "\r\n" is one Character: consumed at once
        return (sep, start)
    }

    /// Counts `,` / `;` / tab outside quotes in the first line; the most frequent wins, ties go to the comma, a
    /// `.tsv` filename means tab.
    static func sniffDelimiter(firstLineOf text: Substring, filename: String?) -> Character {
        if let filename, (filename as NSString).pathExtension.lowercased() == "tsv" { return "\t" }
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        var inQuotes = false
        for ch in text {
            if ch == "\"" { inQuotes.toggle(); continue }
            if !inQuotes, ch == "\n" || ch == "\r" || ch == "\r\n" { break }
            if !inQuotes, counts[ch] != nil { counts[ch, default: 0] += 1 }
        }
        let best = counts.values.max() ?? 0
        guard best > 0 else { return "," }
        if counts[","] == best { return "," }
        if counts[";"] == best { return ";" }
        return "\t"
    }

    // MARK: - Parsing

    /// RFC 4180 with the usual leniencies: quotes may open a field anywhere it starts, `""` is a literal quote, an
    /// unterminated quote runs to the end, CRLF / LF / CR (mixed) end records, an empty line is an empty record and
    /// a trailing newline adds nothing. Works on Unicode scalars so "\r\n" is two code points, not one Character.
    static func parse(_ text: Substring, delimiter: Character, quote: Character) -> [[String]] {
        let delim = delimiter.unicodeScalars.first!
        let q = quote.unicodeScalars.first!
        let scalars = text.unicodeScalars
        var records: [[String]] = []
        var record: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var fieldStarted = false     // something (even an opening quote) has been seen in the current field
        var recordStarted = false    // something has been seen in the current record

        func endRecord() {
            if recordStarted || fieldStarted || !field.isEmpty { record.append(String(field)) }
            records.append(record)
            record = []; field = String.UnicodeScalarView()
            inQuotes = false; fieldStarted = false; recordStarted = false
        }

        var i = scalars.startIndex
        while i < scalars.endIndex {
            let c = scalars[i]
            let next = scalars.index(after: i)
            if inQuotes {
                if c == q {
                    if next < scalars.endIndex, scalars[next] == q { field.append(q); i = scalars.index(after: next); continue }
                    inQuotes = false
                } else {
                    field.append(c)
                }
                i = next
                continue
            }
            switch c {
            case q where field.isEmpty && !fieldStarted:
                inQuotes = true; fieldStarted = true; recordStarted = true
            case delim:
                record.append(String(field)); field = String.UnicodeScalarView()
                fieldStarted = false; recordStarted = true
            case "\n":
                endRecord()
            case "\r":
                endRecord()
                if next < scalars.endIndex, scalars[next] == "\n" { i = scalars.index(after: next); continue }
            default:
                field.append(c); fieldStarted = true; recordStarted = true
            }
            i = next
        }
        if recordStarted || fieldStarted || !field.isEmpty { endRecord() }
        return records
    }

    // MARK: - Type inference

    struct TypeInference {
        let formatters: [DateFormatter]
        let calendar: Calendar

        init(dateFormats: [String]) {
            formatters = dateFormats.map { pattern in
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone(identifier: "UTC")
                f.dateFormat = pattern
                return f
            }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            calendar = cal
        }

        func value(for s: String) -> CellValue {
            if Self.isInteger(s) {
                if let i = Int(s) { return .integer(i) }
                if let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) { return .number(d) }   // beyond Int64
            }
            if Self.isDecimal(s), let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) { return .number(d) }
            switch s.lowercased() {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: break
            }
            for f in formatters {
                if let date = f.date(from: s), let civil = civilDateTime(from: date) { return .date(civil) }
            }
            if let d = CivilDate(iso: s) { return .date(CivilDateTime(date: d)) }
            if let dt = CivilDateTime(iso: s) { return .date(dt) }
            return .text(s)
        }

        func civilDateTime(from date: Date) -> CivilDateTime? {
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
            guard let y = c.year, let m = c.month, let d = c.day, let civil = CivilDate(year: y, month: m, day: d) else { return nil }
            return CivilDateTime(date: civil, time: TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0, nanosecond: c.nanosecond ?? 0))
        }

        /// Optional sign, then "0" or digits without a leading zero.
        static func isInteger(_ s: String) -> Bool {
            var digits = Substring(s)
            if let first = digits.first, first == "+" || first == "-" { digits = digits.dropFirst() }
            guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit) else { return false }
            return digits.count == 1 || digits.first != "0"
        }

        /// Optional sign, digits with one `.` and / or an exponent (at least one of the two; plain digit runs are the
        /// integer rule's business, so "01234" stays text).
        static func isDecimal(_ s: String) -> Bool {
            var rest = Substring(s)
            if let first = rest.first, first == "+" || first == "-" { rest = rest.dropFirst() }
            var mantissa = rest, exponent: Substring? = nil
            if let e = rest.firstIndex(where: { $0 == "e" || $0 == "E" }) {
                mantissa = rest[..<e]; exponent = rest[rest.index(after: e)...]
            }
            let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count <= 2, parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }), parts.contains(where: { !$0.isEmpty }) else { return false }
            if let exponent {
                var digits = exponent
                if let first = digits.first, first == "+" || first == "-" { digits = digits.dropFirst() }
                guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit) else { return false }
            }
            return parts.count == 2 || exponent != nil
        }
    }

    // MARK: - Rendering

    struct FieldRenderer {
        let options: CSVWriteOptions
        let dateFormatter: DateFormatter?

        init(options: CSVWriteOptions) {
            self.options = options
            if let pattern = options.dateFormat {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone(identifier: "UTC")
                f.dateFormat = pattern
                dateFormatter = f
            } else {
                dateFormatter = nil
            }
        }

        func render(_ value: CellValue, at ref: CellRef, sheet: String, warnings: inout [ConversionWarning]) -> String {
            switch value {
            case .text(let s): return s
            case .richText: return value.textValue ?? ""
            case .integer(let i): return String(i)
            case .number(let d): return "\(d)"
            case .bool(let b): return b ? "TRUE" : "FALSE"
            case .date(let dt):
                if let dateFormatter { return dateFormatter.string(from: Self.date(of: dt)) }
                return dt.isMidnight ? dt.date.description : dt.iso8601
            case .time(let t): return t.iso8601
            case .duration: return value.pythonString
            case .error(let e): return e
            case .formula(_, let cached):
                if let cached { return render(cached, at: ref, sheet: sheet, warnings: &warnings) }
                warnings.append(ConversionWarning(.degraded, sheet: sheet, location: ref, message: "formula without a cached value written as text"))
                return value.pythonString
            }
        }

        static func date(of dt: CivilDateTime) -> Date {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            var c = DateComponents()
            c.year = dt.date.year; c.month = dt.date.month; c.day = dt.date.day
            c.hour = dt.time.hour; c.minute = dt.time.minute; c.second = dt.time.second; c.nanosecond = dt.time.nanosecond
            return cal.date(from: c)!
        }
    }

    /// Quotes when the field holds the delimiter, the quote, CR / LF, or leading / trailing spaces.
    static func quoted(_ field: String, delimiter: Character, quote: Character) -> String {
        let needsQuotes = field.contains { $0 == delimiter || $0 == quote || $0 == "\r" || $0 == "\n" || $0 == "\r\n" }
            || field.hasPrefix(" ") || field.hasSuffix(" ")
        guard needsQuotes else { return field }
        let q = String(quote)
        return q + field.replacingOccurrences(of: q, with: q + q) + q
    }

    // MARK: - Encoding

    static func encode(_ text: String, fields: [(ref: CellRef, text: String)], sheet: String, options: CSVWriteOptions,
                       warnings: inout [ConversionWarning]) throws -> Data {
        let encoding = options.encoding
        let name = String.localizedName(of: encoding)
        var body: Data
        if let exact = text.data(using: encoding) {
            body = exact
        } else {
            let offenders = fields.filter { $0.text.data(using: encoding) == nil }
            guard options.lossy else {
                let place = offenders.first.map { $0.ref.a1 } ?? "?"
                throw SheetError.unsupportedFeature("text at \(place) cannot be represented in \(name)")
            }
            for o in offenders {
                warnings.append(ConversionWarning(.degraded, sheet: sheet, location: o.ref, message: "text cannot be represented in \(name); unencodable characters replaced"))
            }
            guard let lossy = text.data(using: encoding, allowLossyConversion: true) else {
                throw SheetError.unsupportedFeature("text cannot be encoded in \(name)")
            }
            body = lossy
        }
        if options.includeBOM {
            switch encoding {
            case .utf8: body.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0)
            case .utf16LittleEndian: body.insert(contentsOf: [0xFF, 0xFE], at: 0)
            case .utf16BigEndian: body.insert(contentsOf: [0xFE, 0xFF], at: 0)
            default: break   // `.utf16` carries Foundation's own BOM; other encodings have none
            }
        }
        return body
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
