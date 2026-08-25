import Foundation
import Testing
@testable import SheetNumbers
import SwiftSheets

/// What a Numbers cell keeps beside its value: a link, formatting that changes part-way through the text, and a
/// note (spec Appendix B.18). All three were read out of a document Numbers 15.3.1 produced from an `.xlsx`
/// carrying them, and all three are written the same way — Numbers opens the result and keeps them when it saves
/// the document again.
@Suite struct NumbersRichTextTests {
    static func workbook() -> Workbook {
        var wb = Workbook()
        var sheet = wb.sheets[0]
        sheet["A1"] = "visit example"
        sheet[cell: "A1"].hyperlink = Hyperlink(target: "https://example.com/one")
        sheet["A2"] = "second link"
        sheet[cell: "A2"].hyperlink = Hyperlink(target: "https://example.com/two")
        sheet["B1"] = .richText([TextRun("bold", font: Font(bold: true)), TextRun("plain"),
                                 TextRun("red", font: Font(color: Color(hex: "FF0000")))])
        sheet["C1"] = "has a note"
        sheet[cell: "C1"].comment = CellNote("first note text", author: "Author One")
        sheet["C2"] = "another"
        sheet[cell: "C2"].comment = CellNote("second note", author: "Author Two")
        wb.sheets[0] = sheet
        return wb
    }

    @Test func linksRunsAndNotesSurviveARoundTrip() throws {
        let result = try Self.workbook().write(as: .numbers)
        #expect(result.warnings.isEmpty, "\(result.warnings.map(\.message))")
        let read = try NumbersCodec.read(result.data)
        #expect(read.warnings.isEmpty, "\(read.warnings.map(\.message))")
        let back = read.workbook.sheets[0]

        #expect(back["A1"] == .text("visit example"), "a link does not make the text rich")
        #expect(back[cell: "A1"].hyperlink?.target == "https://example.com/one")
        #expect(back[cell: "A2"].hyperlink?.target == "https://example.com/two")

        guard case .richText(let runs)? = back["B1"] else {
            Issue.record("B1 came back as \(String(describing: back["B1"]))")
            return
        }
        #expect(runs.map(\.text) == ["bold", "plain", "red"])
        #expect(runs[0].font?.bold == true)
        #expect(runs[1].font == nil, "a run that varies nothing carries no font")
        #expect(runs[2].font?.color == Color(hex: "FF0000"))

        #expect(back[cell: "C1"].comment?.text == "first note text")
        #expect(back[cell: "C1"].comment?.author == "Author One")
        #expect(back[cell: "C2"].comment?.text == "second note")
        #expect(back[cell: "C2"].comment?.author == "Author Two")
    }

    /// Two notes by one person share one author archive, and every author is registered with the document's own
    /// author storage — Numbers looks for them there.
    @Test func authorsAreSharedAndRegistered() throws {
        var wb = Workbook()
        var sheet = wb.sheets[0]
        for r in 0..<3 {
            sheet[CellRef(row: r, col: 0)] = .text("row \(r)")
            sheet[cell: CellRef(row: r, col: 0)].comment = CellNote("note \(r)", author: "One Person")
        }
        wb.sheets[0] = sheet
        let doc = try NumbersDocument(data: try wb.write(as: .numbers).data)
        let authors = doc.identifiers(ofType: "TSK.AnnotationAuthorArchive")
        #expect(authors.count == 1, "three notes by one person, one author")
        guard let storage = doc.identifiers(ofType: "TSK.AnnotationAuthorStorageArchive").first else {
            Issue.record("no author storage")
            return
        }
        #expect(doc.object(storage)?.references("annotation_author").contains(authors[0]) == true)
    }

    /// Numbers writes the paragraph tables even for one line of cell text, and refuses a document whose cell
    /// storage lacks them. Nothing but Numbers itself notices, so the shape is held here.
    @Test func cellTextCarriesTheParagraphTablesNumbersExpects() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "linked"
        wb.sheets[0][cell: "A1"].hyperlink = Hyperlink(target: "https://example.com/")
        let doc = try NumbersDocument(data: try wb.write(as: .numbers).data)
        let storages = doc.identifiers(ofType: "TSWP.StorageArchive").compactMap { doc.object($0) }
            .filter { $0.int("kind") == 5 && $0.strings("text").joined() == "linked" }
        #expect(storages.count == 1)
        let storage = storages[0]
        for field in ["table_para_style", "table_para_data", "table_list_style", "table_para_starts", "table_smartfield"] {
            #expect(storage.has(field), "cell storage is missing \(field)")
        }
        #expect(storage.bool("in_document") == true)
    }

    /// The same three things read out of a document **Numbers 15.3.1 itself wrote** — the corpus was Numbers
    /// 11–14 era until this pair was added (MAINTENANCE.md). numbers-parser checks the values cell by cell in
    /// `NumbersReaderTests`; the note and the link are ours alone to check, because it exposes neither.
    @Test func readsWhatNumbersFifteenWrote() throws {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/numbers/links-notes-15.numbers")
        let result = try NumbersCodec.read(try Data(contentsOf: url))
        #expect(result.warnings.isEmpty, "\(result.warnings.map(\.message))")
        let data = result.workbook.sheets[0]

        #expect(data[cell: "A1"].hyperlink?.target == "https://example.com/one")
        #expect(data[cell: "A2"].hyperlink?.target == "https://example.com/two")
        #expect(data[cell: "C1"].comment?.text == "first note text")
        #expect(data[cell: "C1"].comment?.author == "Author One")
        #expect(data[cell: "C2"].comment?.text == "second note\nwith two lines")

        // and the formulas that reach into the other sheet's table
        guard case .formula(let expr, _)? = data["D1"] else {
            Issue.record("D1 came back as \(String(describing: data["D1"]))")
            return
        }
        #expect(expr.rendered(as: .xlsx).contains("!A1*2"), "\(expr.rendered(as: .xlsx))")
        #expect(expr.referencedSheets.contains { $0.hasPrefix("Other::") }, "\(expr.referencedSheets)")
    }
}
