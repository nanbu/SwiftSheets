import Foundation
import Testing
@testable import SheetCore
@testable import SheetODS
@testable import SheetXLSX
import SwiftSheets

/// Cell notes in XLSX. Appendix B.7 had "コメントの書き出し（VML）" as未着手: notes were preserved as opaque parts
/// when a workbook was written back, but never *read* into the model and never generated — so a note written in
/// LibreOffice and converted through SwiftSheets came out the other side missing, with a `dropped` warning saying so.
@Suite struct CommentTests {
    static func fixture(_ path: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(path))
    }

    // openpyxl: comments/tests/test_comment_reader.py::test_read_comments
    // openpyxl: comments/tests/test_comment_reader.py::test_comments_cell_association
    // openpyxl: comments/tests/test_comment_sheet.py::TestCommentSheet::test_read_comments
    // openpyxl: comments/tests/test_author.py::TestAuthor::test_from_xml
    @Test func readsNotesFromAWorkbook() throws {
        let wb = try Workbook(data: try Self.fixture("preservation/charts-and-friends.xlsx"))
        let note = try #require(wb.sheets[0][cell: "A1"].comment)
        #expect(!note.text.isEmpty)
        #expect(wb.sheets[1][cell: "A2"].comment != nil)
    }

    /// The whole point of the pair: the comments part carries the text, the VML carries the shape. Without the VML
    /// Excel asks to repair the file.
    // openpyxl: comments/tests/test_comment_sheet.py::TestCommentSheet::test_from_comments
    // openpyxl: comments/tests/test_shape_writer.py::test_write_comments_vml
    @Test func writesBothParts() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "値"
        wb.sheets[0][cell: "A1"].comment = CellNote("確認してください\n2 行目", author: "南部")
        wb.sheets[0][cell: "C3"].comment = CellNote("another", author: "B")
        let data = try wb.data(as: .xlsx)
        let zip = try ZipInspection(data: data)

        let comments = String(decoding: try #require(zip.entry(named: "xl/comments/comment1.xml")), as: UTF8.self)
        #expect(comments.contains("<author>南部</author>") && comments.contains("<author>B</author>"))
        #expect(comments.contains("ref=\"A1\" authorId=\"0\""))
        #expect(comments.contains("ref=\"C3\" authorId=\"1\""))
        #expect(comments.contains("確認してください\n2 行目"))

        let vml = String(decoding: try #require(zip.entry(named: "xl/drawings/commentsDrawing1.vml")), as: UTF8.self)
        #expect(vml.components(separatedBy: "ObjectType=\"Note\"").count == 3)   // two shapes
        #expect(vml.contains("<x:Row>0</x:Row><x:Column>0</x:Column>"))
        #expect(vml.contains("<x:Row>2</x:Row><x:Column>2</x:Column>"))

        // and the worksheet points at the VML, the content types declare both
        let sheet = String(decoding: try #require(zip.entry(named: "xl/worksheets/sheet1.xml")), as: UTF8.self)
        let rels = String(decoding: try #require(zip.entry(named: "xl/worksheets/_rels/sheet1.xml.rels")), as: UTF8.self)
        let id = try #require(sheet.components(separatedBy: "<legacyDrawing r:id=\"").dropFirst().first?.prefix { $0 != "\"" })
        #expect(rels.contains("Id=\"\(id)\""))
        let ct = String(decoding: try #require(zip.entry(named: "[Content_Types].xml")), as: UTF8.self)
        #expect(ct.contains("Extension=\"vml\""))
        #expect(ct.contains("PartName=\"/xl/comments/comment1.xml\""))
    }

    @Test func notesSurviveARoundTrip() throws {
        var wb = Workbook()
        wb.sheets[0][cell: "B2"].comment = CellNote("メモ", author: "作者")
        wb.addSheet(named: "Two")
        wb.sheets[1][cell: "D4"].comment = CellNote("second sheet")
        let again = try Workbook(data: try wb.data(as: .xlsx))
        #expect(again.sheets[0][cell: "B2"].comment == CellNote("メモ", author: "作者"))
        #expect(again.sheets[1][cell: "D4"].comment?.text == "second sheet")
        #expect(again.sheets[1][cell: "D4"].comment?.author == "")
    }

    // openpyxl: comments/tests/test_shape_writer.py::test_shape_with_custom_size
    @Test func noteSizesSurvive() throws {
        var wb = Workbook()
        var note = CellNote("大きい", author: "A")
        note.width = 260; note.height = 130
        wb.sheets[0][cell: "A1"].comment = note
        let again = try Workbook(data: try wb.data(as: .xlsx))
        #expect(again.sheets[0][cell: "A1"].comment?.width == 260)
        #expect(again.sheets[0][cell: "A1"].comment?.height == 130)
    }

    /// The reason this had to be done: a note written in LibreOffice reached .xlsx as a warning, not as a note.
    @Test func aNoteConvertedFromODSArrives() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "値"
        wb.sheets[0][cell: "A1"].comment = CellNote("ODS 由来のメモ", author: "LibreOffice")
        let viaODS = try Workbook(data: try wb.data(as: .ods))
        #expect(viaODS.sheets[0][cell: "A1"].comment?.text == "ODS 由来のメモ")
        let result = try viaODS.write(as: .xlsx)
        #expect(!result.warnings.contains { $0.message.contains("note") })
        #expect(try Workbook(data: result.data).sheets[0][cell: "A1"].comment?.text == "ODS 由来のメモ")
    }

    /// Editing a note rewrites the source's own parts in place — the sheet keeps pointing at the same paths, so
    /// nothing else in the package has to move.
    @Test func editingANoteRewritesTheSourcePartsInPlace() throws {
        var wb = try Workbook(data: try Self.fixture("preservation/charts-and-friends.xlsx"))
        wb.sheets[0][cell: "A1"].comment = CellNote("差し替え", author: "南部")
        let data = try wb.data(as: .xlsx)
        let zip = try ZipInspection(data: data)
        let comments = String(decoding: try #require(zip.entry(named: "xl/comments/comment1.xml")), as: UTF8.self)
        #expect(comments.contains("差し替え"))
        #expect(zip.contains("xl/drawings/commentsDrawing1.vml"))
        // the second sheet was not touched, so its parts are still the source's bytes
        let before = try ZipInspection(data: try Self.fixture("preservation/charts-and-friends.xlsx"))
        #expect(zip.entry(named: "xl/comments/comment2.xml") == before.entry(named: "xl/comments/comment2.xml"))
        #expect(try Workbook(data: data).sheets[0][cell: "A1"].comment?.text == "差し替え")
    }

    /// Removing every note on a sheet takes the parts, their relationships and the `<legacyDrawing>` with them —
    /// a dangling r:id is exactly the kind of thing Excel offers to repair.
    @Test func removingEveryNoteRemovesTheParts() throws {
        var wb = try Workbook(data: try Self.fixture("preservation/charts-and-friends.xlsx"))
        for i in wb.sheets.indices {
            for (ref, _) in wb.sheets[i].notes { wb.sheets[i][cell: ref].comment = nil }
        }
        let data = try wb.data(as: .xlsx)
        let zip = try ZipInspection(data: data)
        #expect(!zip.contains("xl/comments/comment1.xml"))
        #expect(!zip.contains("xl/comments/comment2.xml"))
        let sheet = String(decoding: try #require(zip.entry(named: "xl/worksheets/sheet1.xml")), as: UTF8.self)
        let rels = String(decoding: zip.entry(named: "xl/worksheets/_rels/sheet1.xml.rels") ?? Data(), as: UTF8.self)
        #expect(!sheet.contains("<legacyDrawing"))
        #expect(!rels.contains("/comments"))
        let ct = String(decoding: try #require(zip.entry(named: "[Content_Types].xml")), as: UTF8.self)
        #expect(!ct.contains("comment1.xml"))
        // …and every id the sheet still names resolves
        for id in sheet.components(separatedBy: "r:id=\"").dropFirst().compactMap({ $0.split(separator: "\"").first }) {
            #expect(rels.contains("Id=\"\(id)\""), "dangling \(id)")
        }
    }
}
