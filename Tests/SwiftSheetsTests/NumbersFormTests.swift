import Foundation
import Testing
@testable import SheetCore
@testable import SheetNumbers
import SwiftSheets

/// Tabs in a Numbers document that are not sheets of cells (spec Appendix B.36).
///
/// A **form** is Numbers' data-entry view: you build it on an iPhone or an iPad, it sits in the tab bar beside the
/// sheets, and typing into it fills in a table that already exists somewhere else. It holds no values of its own.
///
/// The reader used to keep only the tabs whose archive was a plain sheet, and a form went by without a word — the
/// one thing this library promises never to do. The fixture is the maintainer's own, made on an iPhone, because a
/// form cannot be made on a Mac and this project does not invent specimens it has no example of.
@Suite struct NumbersFormTests {
    static func fixture() throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/numbers/form-15.numbers"))
    }

    @Test func theTableTheFormFillsInIsReadAsUsual() throws {
        let result = try NumbersCodec.read(try Self.fixture())
        let wb = result.workbook
        // one tab of cells, though the document has two tabs: the other one is the form
        #expect(wb.sheetNames == ["シート1"])
        #expect(wb.sheets[0].tables.count == 1)
        #expect(wb.sheets[0].table.name == "表1")
        #expect(wb.sheets[0]["A1"] == .text("名前"))
        #expect(wb.sheets[0]["A2"] == .text("フォームテスト"))
        #expect(wb.sheets[0]["B4"] == .text("さしすせそ"))
    }

    @Test func theFormItselfIsReportedRatherThanPassedOver() throws {
        let result = try NumbersCodec.read(try Self.fixture())
        #expect(result.warnings.count == 1)
        let said = try #require(result.warnings.first)
        #expect(said.kind == .dropped)
        #expect(said.subject == .sheets)
        // it names the form, and the table typing into it fills in — enough to know what was lost and what was not
        #expect(said.message.contains("表1フォーム"))
        #expect(said.message.contains("シート1::表1"))
    }

    /// The document really does carry a form: the reader is not being told about something that is not there.
    @Test func theFixtureCarriesAFormArchive() throws {
        let doc = try NumbersDocument(data: try Self.fixture())
        #expect(doc.identifiers(ofType: "TN.FormBasedSheetArchive").count == 1)
        #expect(doc.identifiers(ofType: "TN.SheetArchive").count == 1)
    }

    /// Writing it back keeps the table and loses the form, which is what the read warning said would happen.
    @Test func writingItBackKeepsTheTableAndSaysNothingNew() throws {
        let wb = try NumbersCodec.read(try Self.fixture()).workbook
        let out = try wb.write(as: .numbers)
        let back = try Workbook(data: out.data)
        #expect(back.sheetNames == ["シート1"])
        #expect(back.sheets[0]["A2"] == .text("フォームテスト"))
        #expect(back.readWarnings.isEmpty)      // nothing left to lose: the form went at the first read
    }
}
