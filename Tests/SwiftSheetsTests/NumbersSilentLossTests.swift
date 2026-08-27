import Foundation
import Testing
@testable import SheetNumbers
import SwiftSheets

/// The library's central promise is that nothing is dropped in silence (README, spec §10.3). A Numbers sheet is a
/// canvas, not a grid: charts, images and shapes stand on it beside the tables, and a cell can carry an interactive
/// control. None of it fits the model — which is allowed — but until this suite existed none of it was *reported*,
/// because every fixture in the corpus was a document containing tables and nothing else.
///
/// `chart-and-control-15.numbers` is the corpus's first document with something other than a table in it: a chart
/// and a pop-up menu, produced by Numbers 15.3.1 importing an openpyxl workbook (see MAINTENANCE.md). Theme images
/// and previews are stripped, as with the other Numbers 15 fixtures; Numbers still opens it.
@Suite struct NumbersSilentLossTests {
    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appending(path: "Fixtures/numbers/\(name)"))
    }

    @Test func aChartOnTheSheetIsReported() throws {
        let result = try NumbersCodec.read(try Self.fixture("chart-and-control-15.numbers"))
        let charts = result.warnings.filter { $0.subject == .objects && $0.message.contains("chart") }
        #expect(charts.count == 1, Comment(rawValue: "expected exactly one chart warning, got \(result.warnings.map(\.message))"))
        #expect(charts.first?.kind == .dropped)
        #expect(charts.first?.sheet == result.workbook.sheets[0].name)
    }

    /// A pop-up menu is no longer reported as a loss: it comes back as a `.list` validation instead. The warning
    /// stays for the controls the model has no word for (checkbox, stepper, slider, rating).
    @Test func aPopUpMenuIsAValidationNotAWarning() throws {
        let result = try NumbersCodec.read(try Self.fixture("chart-and-control-15.numbers"))
        let controls = result.warnings.filter { $0.message.contains("control") }
        #expect(controls.isEmpty, Comment(rawValue: "a pop-up menu is read, not warned about: \(controls.map(\.message))"))
        let rules = result.workbook.sheets[0].dataValidations
        #expect(rules.count == 1)
        #expect(rules.first?.kind == .list)
        #expect(rules.first?.formula1 == "\"one,two,three\"")
    }

    /// The value under a control is still read — with the pop-up, not instead of it.
    @Test func theValueUnderAControlSurvives() throws {
        let wb = try Workbook(data: try Self.fixture("chart-and-control-15.numbers"), format: .numbers)
        let sheet = wb.sheets[0]
        #expect(sheet["A2"]?.textValue == "apple")
        #expect(sheet["C2"]?.textValue == "one")      // the pop-up menu's selected item
    }

    /// The other side of the promise: a document that holds only tables must not be given warnings it has not earned.
    /// Numbers writes an empty filter set and category order into every table, so presence alone cannot be the test.
    @Test(arguments: ["test-1.numbers", "test-2.numbers", "test-formats.numbers", "links-notes-15.numbers",
                      "conditional-formats-15.numbers", "test-empty-rows.numbers"])
    func aTableOnlyDocumentGainsNoObjectWarnings(_ name: String) throws {
        let result = try NumbersCodec.read(try Self.fixture(name))
        let noise = result.warnings.filter { $0.subject == .objects || $0.message.contains("control") }
        #expect(noise.isEmpty, Comment(rawValue: "\(name) should report no objects: \(noise.map(\.message))"))
    }
}
