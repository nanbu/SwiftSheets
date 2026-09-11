import Foundation
import Testing
@testable import SheetNumbers
import SwiftSheets

/// The print setup on a Numbers sheet archive (spec Appendix B.84): orientation, scale, margins, the first page
/// number and the odd header / footer, split into Numbers' three zones. What the archive cannot hold is named.
@Suite struct NumbersPrintTests {
    @Test func writesTheSetupTheSheetArchiveHoldsAndReadsItBack() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "print"
        wb.sheets[0].pageSetup.orientation = .landscape
        wb.sheets[0].pageSetup.scale = 80
        wb.sheets[0].pageSetup.firstPageNumber = 5
        wb.sheets[0].pageMargins.top = 1.5; wb.sheets[0].pageMargins.left = 0.5
        wb.sheets[0].headerFooter.oddHeader = "&L社外秘&CTitle&RRight"
        wb.sheets[0].headerFooter.oddFooter = "&LDrawn &D&R&P"
        let result = try wb.write(as: .numbers)
        #expect(result.warnings.contains { $0.kind == .degraded && $0.message.contains("&D dropped") }, "\(result.warnings.map(\.message))")
        #expect(result.warnings.contains { $0.kind == .degraded && $0.message.contains("page number (&P) is drawn where Numbers draws it") })
        #expect(!result.warnings.contains { $0.message.contains("print setup") }, "the old blanket warning is gone")
        let back = try Workbook(data: result.data).sheets[0]
        #expect(back.pageSetup.orientation == .landscape)
        #expect(back.pageSetup.scale == 80)
        #expect(back.pageSetup.firstPageNumber == 5 && back.pageSetup.usesFirstPageNumber == true)
        #expect(back.pageMargins.top == 1.5 && back.pageMargins.left == 0.5)
        #expect(back.headerFooter.oddHeader == "&L社外秘&CTitle&RRight")
        #expect(back.headerFooter.oddFooter == "&LDrawn &C&P", "the date is gone, the page number is centred")
    }

    /// A Numbers document prints a centred page number unless told otherwise, at 72 % with its own margins —
    /// what the template says, read faithfully.
    @Test func readsNumbersOwnDefaults() throws {
        var wb = Workbook(); wb.sheets[0]["A1"] = 1
        let back = try Workbook(data: try wb.write(as: .numbers).data).sheets[0]
        #expect(back.pageSetup.orientation == nil)
        #expect(back.pageSetup.scale == 72)
        #expect(back.headerFooter.oddHeader == nil)
        #expect(back.headerFooter.oddFooter == "&C&P")
        #expect(back.pageMargins.top == 0.75 && back.pageMargins.left == 0.5)
    }

    @Test func aFooterWithoutAPageNumberTurnsNumbersPageNumbersOff() throws {
        var wb = Workbook(); wb.sheets[0]["A1"] = 1
        wb.sheets[0].headerFooter.oddFooter = "&CConfidential"
        let data = try wb.write(as: .numbers).data
        let back = try Workbook(data: data).sheets[0]
        #expect(back.headerFooter.oddFooter == "&CConfidential")
        let doc = try NumbersDocument(data: data)
        let sheet = doc.object(doc.object(NumbersDocument.documentID)!.references("sheets")[0])!
        #expect(sheet.bool("show_page_numbers") == false)
    }

    @Test func whatTheArchiveCannotHoldIsNamed() throws {
        var wb = Workbook(); wb.sheets[0]["A1"] = 1
        wb.sheets[0].pageSetup.paperSize = 99   // not in the table
        wb.sheets[0].pageSetup.fitToWidth = 1
        wb.sheets[0].printAreaFormula = "A1:B2"
        wb.sheets[0].printTitleRows = 3...4      // not from row 1
        wb.sheets[0].rowBreaks = [3]
        wb.sheets[0].headerFooter.differentFirst = true
        wb.sheets[0].headerFooter.firstHeader = "first"
        let result = try wb.write(as: .numbers)
        #expect(result.warnings.contains { $0.kind == .dropped && $0.message.contains("paper size 99, print area, title rows 3-4, page breaks are dropped") }, "\(result.warnings.map(\.message))")
        #expect(result.warnings.contains { $0.kind == .degraded && $0.message.contains("fit-to-pages is written as Numbers' auto-fit") })
        #expect(result.warnings.contains { $0.kind == .dropped && $0.message.contains("even-page / first-page header") })
    }

    /// The paper is one for the document (B.86); title rows starting at row 1 are the header rows repeated on
    /// every page; what has no place is named.
    @Test func carriesThePaperAndTheTitleRows() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "h"; wb.sheets[0]["A2"] = 1; wb.sheets[0]["A3"] = 2
        wb.sheets[0].pageSetup.paperSize = 1   // Letter
        wb.sheets[0].printTitleRows = 1...1
        wb.sheets[0].printTitleColumns = 1...1
        wb.addSheet(named: "Other"); wb.sheets[1]["A1"] = 1
        wb.sheets[1].pageSetup.paperSize = 9   // A4: the document already has Letter
        wb.sheets[1].printTitleRows = 2...3
        let result = try wb.write(as: .numbers)
        #expect(result.warnings.contains { $0.kind == .degraded && $0.message.contains("paper size 9 is written as 1") }, "\(result.warnings.map(\.message))")
        #expect(result.warnings.contains { $0.kind == .dropped && $0.message.contains("title rows 2-3") })
        #expect(!result.warnings.contains { $0.message.contains("paper size 1") })
        let back = try Workbook(data: result.data)
        #expect(back.sheets[0].pageSetup.paperSize == 1 && back.sheets[1].pageSetup.paperSize == 1)
        #expect(back.sheets[0].printTitleRows == 1...1 && back.sheets[0].printTitleColumns == 1...1)
        #expect(back.sheets[0].freezePanes == CellRef("B2"), "the header rows / columns are frozen panes too")
        #expect(back.sheets[1].printTitleRows == nil)
        let doc = try NumbersDocument(data: result.data)
        #expect(doc.object(NumbersDocument.documentID)?.string("paper_id") == "na-letter")
    }

    @Test func titleRowsAndFrozenRowsThatDifferAreSaid() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "h"; wb.sheets[0]["A2"] = 1; wb.sheets[0]["A3"] = 2; wb.sheets[0]["A4"] = 3
        wb.sheets[0].freezePanes = CellRef("A3")   // two frozen rows
        wb.sheets[0].printTitleRows = 1...1        // one title row
        let result = try wb.write(as: .numbers)
        #expect(result.warnings.contains { $0.kind == .degraded && $0.message.contains("title rows (1) and the frozen rows (2) differ") }, "\(result.warnings.map(\.message))")
        #expect(try Workbook(data: result.data).sheets[0].printTitleRows == 1...1)
    }

    @Test func splitsAndStripsCodes() {
        let z = NumbersPrint.split("&L左&C中&R右")
        #expect(z.left == "左" && z.center == "中" && z.right == "右")
        #expect(NumbersPrint.split("plain").center == "plain")
        let p = NumbersPrint.plainText("Page &P of &N && &\"Arial,Bold\"&12x")
        #expect(p.text == "Page  of  & x" && p.pageNumber && p.dropped == ["&N", "&\"Arial,Bold\"", "&12"])
    }

    /// Numbers itself keeps the landscape page and the header text when it saves the document again.
    @Test(.enabled(if: NumbersCanvasTests.numbersCanJudge, "Numbers.app is not here, or this terminal may not drive it"))
    func numbersItselfKeepsTheOrientationAndTheHeader() throws {
        let stage = NumbersCanvasTests.stage
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        var wb = Workbook()
        wb.sheets[0]["A1"] = "print"
        wb.sheets[0].pageSetup.orientation = .landscape
        wb.sheets[0].headerFooter.oddHeader = "&LSwiftSheets&RRight"
        wb.sheets[0].headerFooter.oddFooter = "&C&P"
        let written = stage.appending(path: "print.numbers")
        try wb.write(as: .numbers).data.write(to: written)
        let resaved = stage.appending(path: "print-resaved.numbers")
        let run = try #require(NumbersCanvasTests.numbersApp(["resave", written.path, resaved.path]))
        try #require(run.status == 0, Comment(rawValue: "Numbers did not save the document again: \(run.output)"))
        let back = try Workbook(data: try Data(contentsOf: resaved)).sheets[0]
        #expect(back.pageSetup.orientation == .landscape)
        #expect(back.headerFooter.oddHeader == "&LSwiftSheets&RRight")
        #expect(back.headerFooter.oddFooter == "&C&P")
    }
}
