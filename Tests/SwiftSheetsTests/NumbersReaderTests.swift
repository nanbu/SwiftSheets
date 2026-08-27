import Foundation
import Testing
@testable import SheetCore
@testable import SheetNumbers
import SwiftSheets

/// Cross-implementation check (spec §11.3 / §12.2): what numbers-parser reads from each fixture
/// (`<name>.expected.json`, produced by Tests/NumbersParity/dump_with_numbers_parser.py) must match what we read.
@Suite struct NumbersReaderTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/numbers")
    /// The `-15` pair are documents **Numbers 15.3.1 produced** — the corpus was Numbers 11–14 era until then
    /// (MAINTENANCE.md, spec Appendix B.18).
    static let names = ["issue-3", "issue-18", "simple-func", "test-empty-rows", "test-xref-coverage", "test-2",
                        "test-10", "test-1", "test-formats", "test-hlinks", "issue-17",
                        "conditional-formats-15", "links-notes-15", "popup-15", "controls-15", "array-15", "stock-15",
                        "pivot-mixed-15"]

    struct Expected: Decodable {
        struct Cell: Decodable { let v: JSONValue?; let f: String? }
        struct Table: Decodable { let name: String; let rows: Int; let cols: Int; let merges: [String]; let cells: [String: Cell] }
        struct Sheet: Decodable { let name: String; let tables: [Table] }
        let sheets: [Sheet]
    }
    enum JSONValue: Decodable, Equatable {
        case string(String), number(Double), bool(Bool)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let d = try? c.decode(Double.self) { self = .number(d) }
            else { self = .string(try c.decode(String.self)) }
        }
    }

    /// numbers-parser's formula dialect → ours, for the comparable subset.
    /// numbers-parser renders a formula the way Numbers shows it; the model speaks the XLSX dialect. The
    /// operators are one substitution each. A reference to another table is spelled `Sheet::Table::A1` there and
    /// `\'Sheet::Table\'!A1` here, so the last `::` becomes the `!` and the name is quoted.
    static func normalize(_ f: String) -> String {
        var out = f.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
                   .replacingOccurrences(of: "≥", with: ">=").replacingOccurrences(of: "≤", with: "<=")
                   .replacingOccurrences(of: "≠", with: "<>")
        // `Other::Table 1::A1` → `'Other::Table 1'!A1`, including inside a range or a function call
        let pattern = #"([\p{L}\p{N} _]+::[\p{L}\p{N} _]+)::(\$?[A-Z]+\$?\d+|\$?[A-Z]+|\$?\d+)"#
        while let range = out.range(of: pattern, options: .regularExpression) {
            let piece = String(out[range])
            let parts = piece.components(separatedBy: "::")
            guard parts.count >= 3 else { break }
            let table = parts.dropLast().joined(separator: "::")
            out.replaceSubrange(range, with: "'" + table + "'!" + parts[parts.count - 1])
        }
        return out
    }

    @Test(arguments: names) func matchesNumbersParser(_ name: String) throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name + ".numbers"))
        let result = try NumbersCodec.read(data)
        let (wb, warnings) = (result.workbook, result.warnings)
        let expected = try JSONDecoder().decode(Expected.self, from: try Data(contentsOf: Self.fixtures.appendingPathComponent(name + ".expected.json")))
        #expect(wb.sheetNames == expected.sheets.map(\.name), "\(name): sheet names")
        #expect(wb.sourceInfo?.format == .numbers)
        var formulaChecks = 0, cellChecks = 0
        for (sheet, es) in zip(wb.sheets, expected.sheets) {
            #expect(sheet.tables.count == es.tables.count, "\(name)/\(sheet.name): table count")
            for (table, et) in zip(sheet.tables, es.tables) {
                #expect(table.name == et.name, "\(name): table name")
                #expect(table.nextAppendRow == et.rows, "\(name)/\(et.name): row count")
                let ours = table.cells.filter { $0.value.value != nil }
                #expect(ours.count == et.cells.count, "\(name)/\(et.name): cell count ours \(ours.count) vs \(et.cells.count)")
                for (key, ec) in et.cells {
                    let parts = key.split(separator: ",").map { Int($0)! }
                    let ref = CellRef(row: parts[0], col: parts[1])
                    guard let value = table[ref] else { Issue.record("\(name)/\(et.name) \(ref.a1): missing (expected \(String(describing: ec.v)))"); continue }
                    cellChecks += 1
                    let plain = value.cachedValue
                    switch ec.v {
                    case .string(let s)?:
                        if s == "#ERROR" { #expect(plain?.errorValue != nil, "\(name) \(ref.a1): error expected") }
                        else if s.count == 19, s[s.index(s.startIndex, offsetBy: 10)] == "T", plain?.dateValue != nil {
                            #expect(plain?.dateValue?.iso8601.prefix(19) == s.prefix(19), "\(name) \(ref.a1): date")
                        } else { #expect(plain?.textValue == s, "\(name) \(ref.a1): text \(String(describing: plain))") }
                    case .number(let d)?:
                        if let dur = plain?.durationValue { #expect(abs(Double(dur.components.seconds) - d) < 1, "\(name) \(ref.a1): duration") }
                        else { #expect(plain?.doubleValue.map { abs($0 - d) < 1e-9 } == true, "\(name) \(ref.a1): number \(String(describing: plain)) vs \(d)") }
                    case .bool(let b)?: #expect(plain?.boolValue == b, "\(name) \(ref.a1): bool")
                    case nil: break
                    }
                    if let f = ec.f, !f.contains("UNDEFINED!") {
                        // "UNDEFINED!" is numbers-parser's rendering of the unnamed spill function (337): our
                        // reader deliberately reads such a cell as the covered value of an array formula (B.26),
                        // so there is no reference rendering to compare against
                        #expect(value.formula != nil, "\(name) \(ref.a1): formula expected (\(f))")
                        // a cross-table *range* is rendered by numbers-parser without its cell addresses
                        // (`SUM(Other::Table 1:Table 1)`), so there is nothing left to compare against
                        let degenerate = Self.normalize(f).contains("::")
                        if !f.contains("'"), !degenerate, let ours = value.formula {   // named-column references are numbers-parser's own rendering
                            formulaChecks += 1
                            // numbers-parser keeps the user's parentheses; our text comes from the tree, so compare trees
                            #expect(FormulaExpr.parse(Self.normalize(f)) == ours, "\(name) \(ref.a1): formula \(ours.rendered(as: .xlsx)) vs \(f)")
                        }
                    } else {
                        #expect(value.formula == nil, "\(name) \(ref.a1): unexpected formula")
                    }
                }
                let merges = Set(table.merges.map(\.a1))
                #expect(merges == Set(et.merges), "\(name)/\(et.name): merges \(merges) vs \(et.merges)")
            }
        }
        #expect(cellChecks > 0)
        #expect(warnings.filter { $0.kind == .dropped }.isEmpty, "\(name): \(warnings)")
        _ = formulaChecks
    }

    /// Cell formatting (F1): the fonts, colours, alignment and number formats of a Numbers document.
    ///
    /// The values here were checked against numbers-parser cell by cell over all eleven fixtures — bold, italic,
    /// font name and size, font colour and both alignments agree exactly. Fills differ on purpose: numbers-parser
    /// reads `cell_fill` from the cell's own style only, so it misses the grey a table style gives its header rows,
    /// which SwiftSheets follows up the parent chain (LibreOffice's Numbers import agrees with SwiftSheets there).
    @Test func readsCellFormatting() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("test-2.numbers"))
        let sheet = try NumbersCodec.read(data).workbook.sheets[0]
        let table = sheet.tables[0]
        let header = table.style(at: CellRef(row: 0, col: 0))
        #expect(header.font.bold, "a header row is bold")
        #expect(header.font.name == "Helvetica Neue")
        #expect(header.font.size == 10)
        #expect(header.fill.foregroundColor != nil, "the table style paints its header row")

        // the number formats of the document: sterling with and without a thousands separator, and a date
        let formats = Set(table.cells.values.map(\.style.numberFormat))
        #expect(formats.contains("\"£\"0.00"))
        #expect(formats.contains("\"£\"#,##0.00"))
        #expect(formats.contains("d mmm yyyy"))
        #expect(formats.contains("@"))
    }

    /// A CLDR date pattern (`dd/MM/y HH:mm`) is not an Excel code: the year has to be spelled out.
    @Test func readsDateAndDurationFormats() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("test-10.numbers"))
        let wb = try NumbersCodec.read(data).workbook
        let formats = Set(wb.sheets.flatMap { $0.tables }.flatMap { $0.cells.values }.map(\.style.numberFormat))
        #expect(formats.contains("dd/mm/yyyy hh:mm"))
        #expect(formats.contains("[h]:mm:ss"))
        #expect(formats.contains("0%"))
    }

    /// Hyperlinks: Numbers puts a link on a *run* of a cell's rich text, so a cell can hold several. The model has
    /// one per cell, as Excel does, so the first one is kept and the rest are reported.
    @Test func readsHyperlinks() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("test-hlinks.numbers"))
        let result = try NumbersCodec.read(data)
        let table = result.workbook.sheets[0].tables[0]
        #expect(table.cell("A1")?.hyperlink?.target == "http://news.bbc.co.uk/")
        #expect(table.cell("A2")?.hyperlink?.target == "http://google.co.uk/")
        #expect(result.warnings.contains { $0.kind == .degraded && $0.message.contains("2 links") },
                "the cell that holds two links says so")
    }

    @Test func sourceInfoAndFacade() throws {
        let url = Self.fixtures.appendingPathComponent("test-10.numbers")
        let wb = try Workbook(contentsOf: url)
        #expect(wb.sourceInfo?.format == .numbers)
        #expect(wb.sourceInfo?.version?.hasPrefix("M") == true)
        #expect(SheetFormat.detect(from: try Data(contentsOf: url)) == .numbers)
        #expect(wb.sheets[0].tables[0].name == "Table 1")
    }
}
