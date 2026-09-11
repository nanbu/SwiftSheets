import Foundation
import Testing
@testable import SheetCore
import SwiftSheets
@testable import SheetXLSX
@testable import SheetODS
@testable import SheetCSV
@testable import SheetNumbers

/// The reading fast paths give the answers the slow paths gave: a numeric cell's text is trimmed only when an end is
/// not plain ASCII, an integer under a plain format is tried before a Double, and a namespace prefix is stripped by
/// bytes. Each case below is what the code before those changes answered.
struct HotPathEquivalenceTests {
    /// The value an XLSX reader makes of `<c><v>text</v></c>` under the General format.
    static func value(of text: String, type: String? = nil) throws -> CellValue? {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        let data = try wb.write(as: .xlsx).data
        let sheet = try Package.part("xl/worksheets/sheet1.xml", of: data)
        let t = type.map { " t=\"\($0)\"" } ?? ""
        let patched = sheet.replacingOccurrences(of: "<c r=\"A1\" t=\"s\"><v>0</v></c>", with: "<c r=\"A1\"\(t)><v>\(text)</v></c>")
        #expect(patched.contains("<c r=\"A1\"\(t)><v>\(text)</v></c>"))
        let repacked = try Package.repacking(data, replacing: "xl/worksheets/sheet1.xml", with: Data(patched.utf8))
        let whole = try Workbook.read(repacked, format: .xlsx).workbook.sheets[0]["A1"]
        var streamed: CellValue??
        try StreamingReader(data: repacked, format: .xlsx).forEachRow(inSheet: "Sheet1") { row in streamed = row.cells.first { $0.ref == CellRef("A1")! }?.value }
        #expect((streamed ?? nil) == whole, "the row-by-row reader answers as the whole-workbook reader does for \(text.debugDescription)")
        return whole
    }

    @Test func numbersReadAsTheyDid() throws {
        #expect(try Self.value(of: "42") == .integer(42))
        #expect(try Self.value(of: " 42 ") == .integer(42))
        #expect(try Self.value(of: "\n42\t") == .integer(42))
        #expect(try Self.value(of: "\u{A0}42") == .integer(42), "a non-breaking space is still trimmed")
        #expect(try Self.value(of: "+5") == .integer(5))
        #expect(try Self.value(of: "-0") == .integer(0))
        #expect(try Self.value(of: "4.5") == .number(Decimal(string: "4.5")!))
        #expect(try Self.value(of: "1E3") == .number(Decimal(1000)))
        #expect(try Self.value(of: "12345678901234567890") == .number(Decimal(string: "12345678901234567890")!))
        #expect(try Self.value(of: "abc") == nil)
        #expect(try Self.value(of: "") == nil)
    }

    @Test func sharedStringIndicesAndBooleansReadAsTheyDid() throws {
        #expect(try Self.value(of: "0", type: "s") == .text("x"))
        #expect(try Self.value(of: " 0 ", type: "s") == .text("x"))
        #expect(try Self.value(of: "1", type: "b") == .bool(true))
        #expect(try Self.value(of: " 1", type: "b") == .bool(true))
    }

    @Test func aNamespacePrefixIsStrippedByBytes() {
        #expect(XML.local("x:si") == "si")
        #expect(XML.local("si") == "si")
        #expect(XML.local("a:b:c") == "c")
        #expect(XML.local(":x") == "x")
        #expect(XML.local("x:") == "")
        #expect(XML.local("表:セル") == "セル")
        #expect(XML.local("table:table-cell") == "table-cell")
    }

    /// A dense rectangle's rows are written from the extent; the sheet part is the one the grouped walk writes, byte
    /// for byte — with styles, formulas, a hidden row, and row heights inside and outside the extent.
    @Test func theDenseRowWalkWritesWhatTheGroupedWalkWrites() throws {
        var wb = Workbook()
        for r in 1...50 {
            wb.sheets[0].append([.integer(r), .text("t\(r)"), .number(Decimal(r) / 4), r % 7 == 0 ? .formula("=A\(r)*2") : .bool(r % 2 == 0)])
        }
        wb.sheets[0].setHeight(30, ofRow: 5)
        wb.sheets[0].setHeight(12, ofRow: 80)
        wb.sheets[0].setRowDimension(3) { $0.hidden = true }
        wb.sheets[0].setStyle("B2:B10") { $0.font.bold = true }
        let offset = wb.addSheet(named: "Offset")
        for r in 3...12 { for c in 2...4 { wb.sheets[offset][r, c] = .integer(r * c) } }
        wb.sheets[offset].setHeight(20, ofRow: 1)
        let dense = try wb.write(as: .xlsx).data
        xlsxWriterForcesSparseRowWalk = true
        defer { xlsxWriterForcesSparseRowWalk = false }
        let grouped = try wb.write(as: .xlsx).data
        for part in ["xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"] {
            #expect(try Package.part(part, of: dense) == Package.part(part, of: grouped), Comment(rawValue: part))
        }
    }

    /// Number-like text, including what should not be a number.
    static let numberLike = ["42", " 42 ", "\n42", "42\n", "\u{A0}42", "+5", "-0", "007", "4.5", ".5", "5.", "1e3", "1E3", "-1.25e-3",
                             "12345678901234567890", "9223372036854775807", "9223372036854775808", "-9223372036854775808", "0x10",
                             "abc", "", " ", "\u{661}\u{662}", "1\u{301}", "1,000", "+", "-", "++1"]

    /// The ODS reader's number, against the function it replaced.
    @Test func odsNumbersReadAsTheyDid() {
        func old(_ v: String) -> CellValue? {
            let s = v.trimmingCharacters(in: .whitespaces)
            if !s.contains("."), !s.contains("e"), !s.contains("E"), let i = Int(s) { return .integer(i) }
            guard let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
            return .number(d)
        }
        for v in Self.numberLike { #expect(ContentParser.number(v) == old(v), Comment(rawValue: v.debugDescription)) }
    }

    /// Delimited text's type inference, against the tests it replaced.
    @Test func csvInferenceReadsAsItDid() {
        func oldIsInteger(_ s: String) -> Bool {
            var digits = Substring(s)
            if let first = digits.first, first == "+" || first == "-" { digits = digits.dropFirst() }
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            return digits.count == 1 || digits.first != "0"
        }
        func oldBool(_ s: String) -> Bool? { switch s.lowercased() { case "true": return true; case "false": return false; default: return nil } }
        let inference = CSVCodec.TypeInference(dateFormats: [])
        for v in Self.numberLike + ["true", "TRUE", "False", "fAlSe", "FALSE ", "truE", "yes", "t", "falsee", "\u{130}", "TRU\u{130}"] {
            #expect(CSVCodec.TypeInference.isInteger(v) == oldIsInteger(v), Comment(rawValue: v.debugDescription))
            if let b = oldBool(v), !CSVCodec.TypeInference.isInteger(v), !CSVCodec.TypeInference.isDecimal(v) {
                #expect(inference.value(for: v) == .bool(b), Comment(rawValue: v.debugDescription))
            }
        }
    }

    /// Delimited text's decimal rule and quoting, against the code they replaced — combining marks included, which
    /// the character walk and a byte scan could otherwise answer differently.
    @Test func csvDecimalsAndQuotingAsTheyWere() {
        func oldIsDecimal(_ s: String) -> Bool {
            var rest = Substring(s)
            if let first = rest.first, first == "+" || first == "-" { rest = rest.dropFirst() }
            var mantissa = rest, exponent: Substring? = nil
            if let e = rest.firstIndex(where: { $0 == "e" || $0 == "E" }) { mantissa = rest[..<e]; exponent = rest[rest.index(after: e)...] }
            let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count <= 2, parts.allSatisfy({ $0.allSatisfy({ $0.isASCII && $0.isNumber }) }), parts.contains(where: { !$0.isEmpty }) else { return false }
            if let exponent {
                var digits = exponent
                if let first = digits.first, first == "+" || first == "-" { digits = digits.dropFirst() }
                guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
            }
            return parts.count == 2 || exponent != nil
        }
        func oldQuoted(_ field: String, delimiter: Character, quote: Character) -> String {
            let needsQuotes = field.contains { $0 == delimiter || $0 == quote || $0 == "\r" || $0 == "\n" || $0 == "\r\n" }
                || field.hasPrefix(" ") || field.hasSuffix(" ")
            guard needsQuotes else { return field }
            let q = String(quote)
            return q + field.replacingOccurrences(of: q, with: q + q) + q
        }
        let decimals = Self.numberLike + ["1.2.3", "e5", "1e", "1e+", "+.5", "-.", ".", "1.5E-10", "\u{FF11}.\u{FF15}", "1.\u{301}5", "e\u{301}5", "1e\u{301}5", "1E+05"]
        for v in decimals { #expect(CSVCodec.TypeInference.isDecimal(v) == oldIsDecimal(v), Comment(rawValue: v.debugDescription)) }
        let fields = ["plain", "a,b", "say \"hi\"", "line\nbreak", "cr\rx", "crlf\r\nx", " lead", "trail ", "", " ", "\u{65E5},\u{8A9E}",
                      ",\u{301}", " \u{301}x", "x \u{301}", "tab\tsep", "a;b", "it's"]
        let dialects: [(Character, Character)] = [(",", "\""), (";", "'"), ("\t", "\""), ("\u{FF1B}", "\"")]
        for f in fields {
            for (d, q) in dialects {
                #expect(CSVCodec.quoted(f, delimiter: d, quote: q) == oldQuoted(f, delimiter: d, quote: q), Comment(rawValue: "\(f.debugDescription) \(d) \(q)"))
            }
        }
    }

    /// A Numbers record's decimal128 for an integer, against the long division it skips.
    @Test func numbersIntegersEncodeAsTheyDid() {
        var values = [0, 1, -1, 9, 10, 255, 256, -256, 65_535, 65_536, 1_000_000, -1_000_000, 10_000_000_000, Int(Int32.max), Int(Int32.min),
                      Int.max, Int.min, Int.max - 1, Int.min + 1, 1_000_000_000_000_000_000, -1_000_000_000_000_000_000]
        var x: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<2_000 { x ^= x << 13; x ^= x >> 7; x ^= x << 17; values.append(Int(truncatingIfNeeded: x) >> Int(x % 60)) }
        for i in values {
            #expect(CellStorage.encodeDecimal128(integer: i) == CellStorage.encodeDecimal128(Decimal(i)), Comment(rawValue: "\(i)"))
        }
    }

    /// The package initialisers make exactly the cells the public one makes with its defaults.
    @Test func bareCellsAreThePublicInitialisersCells() {
        #expect(Cell() == Cell(value: nil, style: .default, hyperlink: nil, note: nil))
        #expect(Cell().sharedStyle == nil)
        let day = CivilDate(year: 2026, month: 9, day: 11)!
        let values: [CellValue] = [.integer(3), .text("x"), .number(Decimal(string: "1.5")!), .bool(true), .error("#N/A"),
                                   .date(CivilDateTime(date: day)), .date(CivilDateTime(date: day, time: TimeOfDay(hour: 9, minute: 30))),
                                   .time(TimeOfDay(hour: 9, minute: 30)), .duration(.seconds(90))]
        for v in values {
            let bare = Cell(value: v), full = Cell(value: v, style: .default, hyperlink: nil, note: nil)
            #expect(bare == full, Comment(rawValue: "\(v)"))
            #expect(bare.style.numberFormat == full.style.numberFormat, Comment(rawValue: "\(v)"))
        }
    }

    /// A delimited-text read that reserves its table up front holds the same table.
    @Test func aReservedCSVTableIsTheSameTable() throws {
        var text = ""
        for r in 1...300 { text += "\(r),x\(r),,\(Double(r) / 4)\n" }
        let read = try Workbook.read(Data(text.utf8), format: .csv, options: ReadOptions(csv: CSVReadOptions(inferTypes: true))).workbook
        var expected = Table()
        for r in 1...300 { expected.append([.integer(r), .text("x\(r)"), nil, CellValue.number(Decimal(string: "\(Double(r) / 4)")!)]) }
        let table = read.sheets[0].table
        #expect(table.cells.count == 900)
        #expect(table.extent == expected.extent && table.nextAppendRow == 301)
        #expect(table.cells == expected.cells)
    }
}
