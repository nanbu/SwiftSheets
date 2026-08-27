import Foundation
import Testing
@testable import SheetNumbers
import SwiftSheets

/// A Numbers pop-up menu and a `.list` data validation are the same thing in two vocabularies, and Numbers itself
/// says so: importing an Excel dropdown makes a pop-up, exporting a pop-up makes a strict inline-list dropdown
/// (`allowBlank`, `showInputMessage` and `showErrorMessage` all on). The reader and writer follow that mapping.
///
/// `popup-15.numbers` is Numbers 15.3.1's own import of an openpyxl workbook holding three list rules — text,
/// numbers, and a strict one — over two cells each, one filled and one empty (see MAINTENANCE.md). Numbers made
/// all three the same pop-up shape, which is why strictness does not survive a round trip through it.
@Suite struct NumbersPopUpMenuTests {
    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appending(path: "Fixtures/numbers/\(name)"))
    }

    // MARK: - Reading

    @Test func threePopUpsBecomeThreeListRules() throws {
        let result = try NumbersCodec.read(try Self.fixture("popup-15.numbers"))
        let rules = result.workbook.sheets[0].dataValidations
        #expect(rules.count == 3, Comment(rawValue: "\(rules)"))
        #expect(rules.allSatisfy { $0.kind == .list })
        // the shape Numbers itself exports: strict, blank allowed, messages shown
        #expect(rules.allSatisfy { $0.allowBlank && $0.showInputMessage && $0.showErrorMessage })
        #expect(result.warnings.allSatisfy { !$0.message.contains("control") },
                Comment(rawValue: "\(result.warnings.map(\.message))"))
    }

    @Test func textAndNumberMenusKeepTheirSpelling() throws {
        let result = try NumbersCodec.read(try Self.fixture("popup-15.numbers"))
        let sources = result.workbook.sheets[0].dataValidations.compactMap(\.formula1).sorted()
        #expect(sources == ["\"1,2,3\"", "\"one,two,three\"", "\"red,green,blue\""].sorted())
    }

    @Test func aRuleCoversTheEmptyCellsToo() throws {
        let result = try NumbersCodec.read(try Self.fixture("popup-15.numbers"))
        let rules = result.workbook.sheets[0].dataValidations
        // each rule spans its filled and its empty cell: B2:B3, B4:B5, B6:B7
        let ranges = rules.map { "\($0.ranges)" }.sorted()
        #expect(ranges == ["B2:B3", "B4:B5", "B6:B7"], Comment(rawValue: "\(ranges)"))
    }

    @Test func theSelectedValueIsStillTheCells() throws {
        let wb = try Workbook(data: try Self.fixture("popup-15.numbers"), format: .numbers)
        let sheet = wb.sheets[0]
        #expect(sheet["B2"]?.textValue == "one")
        #expect(sheet["B4"]?.intValue == 2)
        #expect(sheet["B6"]?.textValue == "red")
        #expect(sheet["B3"] == nil)
    }

    // MARK: - Writing

    /// An inline `.list` rule goes out as a real pop-up menu and comes home as one.
    @Test func anInlineListRoundTrips() throws {
        var wb = Workbook()
        var s = wb.sheets[0]
        s.append([CellValue.text("fruit")])
        s.append([CellValue.text("apple")])
        s.dataValidations = [.list("\"apple,banana,cherry\"", over: MultiCellRange("A2:A5")!)]
        wb.sheets[0] = s

        let result = try wb.write(as: .numbers)
        #expect(!result.warnings.contains { $0.message.contains("validation") },
                Comment(rawValue: "\(result.warnings.map(\.message))"))
        let back = try Workbook(data: result.data)
        let rules = back.sheets[0].dataValidations
        #expect(rules.count == 1)
        #expect(rules.first?.kind == .list)
        #expect(rules.first?.formula1 == "\"apple,banana,cherry\"")
        #expect("\(rules.first!.ranges)" == "A2:A5")
        #expect(back.sheets[0]["A2"]?.textValue == "apple")
    }

    /// Numeric choices go out the way Numbers writes them — as numbers, not text — and keep their spelling.
    @Test func aNumericListRoundTrips() throws {
        var wb = Workbook()
        var s = wb.sheets[0]
        s.append([CellValue.integer(2)])
        s.dataValidations = [.list("\"1,2,3\"", over: MultiCellRange("A1:A3")!)]
        wb.sheets[0] = s

        let back = try Workbook(data: try wb.write(as: .numbers).data)
        #expect(back.sheets[0].dataValidations.first?.formula1 == "\"1,2,3\"")
    }

    /// What a pop-up cannot say is still said out loud: a range-sourced list, and every other kind of rule.
    @Test func whatIsNotAPopUpIsStillReported() throws {
        var wb = Workbook()
        var s = wb.sheets[0]
        s.append([CellValue.integer(1)])
        s.dataValidations = [
            .list("Choices!$A$1:$A$3", over: MultiCellRange("A1")!),
            DataValidation(kind: .whole, ranges: MultiCellRange("B1")!, formula1: "1", formula2: "10", operator: .between)
        ]
        wb.sheets[0] = s

        let result = try wb.write(as: .numbers)
        let dropped = result.warnings.filter { $0.message.contains("validation") }
        #expect(dropped.count == 1, Comment(rawValue: "\(result.warnings.map(\.message))"))
        #expect(dropped.first?.message.contains("2") == true, "the warning counts what it dropped")
        let back = try Workbook(data: result.data)
        #expect(back.sheets[0].dataValidations.isEmpty)
    }

    /// A rule over cells that hold nothing still puts the menu there — that is what a dropdown on an entry form is.
    @Test func aPopUpOnAnEmptyCellSurvives() throws {
        var wb = Workbook()
        var s = wb.sheets[0]
        s.append([CellValue.text("pick")])
        s.dataValidations = [.list("\"yes,no\"", over: MultiCellRange("B1:B3")!)]
        wb.sheets[0] = s

        let back = try Workbook(data: try wb.write(as: .numbers).data)
        let rules = back.sheets[0].dataValidations
        #expect("\(rules.first!.ranges)" == "B1:B3")
    }
}
