import Foundation
import Testing
@testable import SheetNumbers
import SwiftSheets

/// The four cell controls with a word in the model — checkbox, stepper, slider, star rating (`CellControl`,
/// spec Appendix B.25). `controls-15.numbers` is a document Numbers 15.3.1 built itself, driven over AppleScript
/// (`set format of range … to checkbox/stepper/slider/rating`), so every wiring assertion below is against
/// Numbers' own placement. Note what Numbers did to the untouched cells: a control cell always holds a value
/// (checkbox → false, stepper → its minimum, rating → 0), which is why writing does the same.
@Suite struct NumbersControlTests {
    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appending(path: "Fixtures/numbers/\(name)"))
    }

    // MARK: - Reading Numbers' own document

    @Test func theFourControlsComeBackAsCellControls() throws {
        let result = try NumbersCodec.read(try Self.fixture("controls-15.numbers"))
        let s = result.workbook.sheets[0]
        #expect(s.cell("B2")?.control?.kind == .checkbox)
        #expect(s.cell("C2")?.control?.kind == .checkbox)
        #expect(s.cell("B3")?.control?.kind == .stepper)
        #expect(s.cell("B4")?.control?.kind == .slider)
        #expect(s.cell("B5")?.control?.kind == .rating)
        #expect(s.cell("C5")?.control?.kind == .rating)
        #expect(result.warnings.allSatisfy { !$0.message.contains("control") },
                Comment(rawValue: "\(result.warnings.map(\.message))"))
    }

    @Test func theDialsBoundsAreReadAsData() throws {
        let wb = try Workbook(data: try Self.fixture("controls-15.numbers"), format: .numbers)
        let s = wb.sheets[0]
        // Numbers itself wrote this stepper with the cell's own value as its maximum — read, not normalised
        #expect(s.cell("B3")?.control == .stepper(minimum: 0, maximum: 4, increment: 1))
        // the untouched neighbour keeps Numbers' default dial
        #expect(s.cell("C3")?.control == .stepper(minimum: 1, maximum: 100, increment: 1))
        #expect(s.cell("C4")?.control == .slider(minimum: 1, maximum: 100, increment: 1))
        #expect(s.cell("B5")?.control == .rating)
    }

    @Test func theValuesUnderTheControlsAreTheCells() throws {
        let wb = try Workbook(data: try Self.fixture("controls-15.numbers"), format: .numbers)
        let s = wb.sheets[0]
        #expect(s["B2"] == .bool(true))
        #expect(s["C2"] == .bool(false))
        #expect(s["B3"]?.intValue == 4)
        #expect(s["B4"]?.intValue == 42)
        #expect(s["B5"]?.intValue == 3)
        #expect(s["C5"]?.intValue == 0)   // Numbers fills an untouched rating with 0
    }

    // MARK: - Writing

    @Test func theFourControlsRoundTripThroughNumbers() throws {
        var wb = Workbook()
        var s = wb.sheets[0]
        s["A1"] = true
        s[cell: "A1"].control = .checkbox
        s["A2"] = 4
        s[cell: "A2"].control = .stepper(minimum: 2, maximum: 8, increment: 2)
        s["A3"] = 30
        s[cell: "A3"].control = .slider(minimum: 0, maximum: 60, increment: 5)
        s["A4"] = 3
        s[cell: "A4"].control = .rating
        wb.sheets[0] = s

        let result = try wb.write(as: .numbers)
        #expect(!result.warnings.contains { $0.message.contains("control") },
                Comment(rawValue: "\(result.warnings.map(\.message))"))
        let back = try Workbook(data: result.data)
        let b = back.sheets[0]
        #expect(b.cell("A1")?.control == .checkbox)
        #expect(b["A1"] == .bool(true))
        #expect(b.cell("A2")?.control == .stepper(minimum: 2, maximum: 8, increment: 2))
        #expect(b["A2"]?.intValue == 4)
        #expect(b.cell("A3")?.control == .slider(minimum: 0, maximum: 60, increment: 5))
        #expect(b.cell("A4")?.control == .rating)
    }

    /// A control cell always holds a value — Numbers itself fills the untouched ones, and so does the writer:
    /// an unchecked checkbox *is* false, an untouched dial sits at its minimum, an unrated row has no stars.
    @Test func anEmptyControlCellGetsItsRestingValue() throws {
        var wb = Workbook()
        var s = wb.sheets[0]
        s["A1"] = "labels"
        s[cell: "B1"].control = .checkbox
        s[cell: "B2"].control = .stepper(minimum: 5, maximum: 10, increment: 1)
        s[cell: "B3"].control = .rating
        wb.sheets[0] = s

        let back = try Workbook(data: try wb.write(as: .numbers).data)
        let b = back.sheets[0]
        #expect(b["B1"] == .bool(false))
        #expect(b.cell("B1")?.control == .checkbox)
        #expect(b["B2"]?.intValue == 5)
        #expect(b["B3"]?.intValue == 0)
    }

    /// A checkbox edits a boolean and a dial edits a number; a cell whose value is neither keeps the value and
    /// loses the control, out loud.
    @Test func aControlOnTheWrongKindOfValueIsDroppedOutLoud() throws {
        var wb = Workbook()
        var s = wb.sheets[0]
        s["A1"] = "words"
        s[cell: "A1"].control = .checkbox
        wb.sheets[0] = s

        let result = try wb.write(as: .numbers)
        let dropped = result.warnings.filter { $0.message.contains("control") }
        #expect(dropped.count == 1 && dropped.first?.kind == .degraded,
                Comment(rawValue: "\(result.warnings.map(\.message))"))
        let back = try Workbook(data: result.data)
        #expect(back.sheets[0]["A1"]?.textValue == "words")
        #expect(back.sheets[0].cell("A1")?.control == nil)
    }

    /// A list rule and a cell control can name the same cell; the cell's own control wins, out loud.
    @Test func aCellControlWinsOverAListRule() throws {
        var wb = Workbook()
        var s = wb.sheets[0]
        s["A1"] = 3
        s[cell: "A1"].control = .rating
        s.dataValidations = [.list("\"a,b\"", over: MultiCellRange("A1:A2")!)]
        wb.sheets[0] = s

        let result = try wb.write(as: .numbers)
        #expect(result.warnings.contains { $0.message.contains("control wins") },
                Comment(rawValue: "\(result.warnings.map(\.message))"))
        let back = try Workbook(data: result.data)
        #expect(back.sheets[0].cell("A1")?.control == .rating)
        // the rule still stands on the cell the control did not claim
        #expect(back.sheets[0].dataValidations.first.map { "\($0.ranges)" } == "A2")
    }

    /// The formats with no word for a control say so instead of going quiet.
    @Test(arguments: [SheetFormat.xlsx, .ods])
    func theOtherFormatsNameTheLoss(_ format: SheetFormat) throws {
        var wb = Workbook()
        var s = wb.sheets[0]
        s["A1"] = true
        s[cell: "A1"].control = .checkbox
        wb.sheets[0] = s

        let result = try wb.write(as: format)
        let named = result.warnings.filter { $0.message.contains("cell control") }
        #expect(named.count == 1, Comment(rawValue: "\(format.rawValue): \(result.warnings.map(\.message))"))
        #expect(named.first?.kind == .dropped)
        // the value itself survives
        let back = try Workbook(data: result.data)
        #expect(back.sheets[0]["A1"] == .bool(true))
    }
}
