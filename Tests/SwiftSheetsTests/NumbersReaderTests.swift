import Foundation
import Testing
@testable import SheetCore
@testable import SheetNumbers
import SwiftSheets

/// Cross-implementation check (spec §11.3 / §12.2): what numbers-parser reads from each fixture
/// (`<name>.expected.json`, produced by Tests/NumbersParity/dump_with_numbers_parser.py) must match what we read.
@Suite struct NumbersReaderTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/numbers")
    static let names = ["issue-3", "issue-18", "simple-func", "test-empty-rows", "test-xref-coverage", "test-2", "test-10", "test-1", "test-formats", "test-hlinks", "issue-17"]

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
    static func normalize(_ f: String) -> String {
        f.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "≥", with: ">=")
         .replacingOccurrences(of: "≤", with: "<=").replacingOccurrences(of: "≠", with: "<>")
    }

    @Test(arguments: names) func matchesNumbersParser(_ name: String) throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name + ".numbers"))
        let (wb, warnings) = try NumbersCodec.readWithWarnings(data)
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
                    if let f = ec.f {
                        #expect(value.formula != nil, "\(name) \(ref.a1): formula expected (\(f))")
                        if !f.contains("'"), let ours = value.formula {   // named-column references are numbers-parser's own rendering
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

    @Test func sourceInfoAndFacade() throws {
        let url = Self.fixtures.appendingPathComponent("test-10.numbers")
        let wb = try Workbook(contentsOf: url)
        #expect(wb.sourceInfo?.format == .numbers)
        #expect(wb.sourceInfo?.version?.hasPrefix("M") == true)
        #expect(SheetFormat.detect(from: try Data(contentsOf: url)) == .numbers)
        #expect(wb.sheets[0].tables[0].name == "Table 1")
    }
}
