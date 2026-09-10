import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// Threaded comments (spec Appendix B.80): read from Excel's threadedComments and persons parts into
/// `cell.thread` (the mirror note hidden), carried as bytes until changed, regenerated with the persons' ids kept;
/// written into ODS and Numbers as notes, out loud.
@Suite(.serialized) struct ThreadedCommentTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/preservation/threaded-comments.xlsx")
    static let tmp: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftSheetsThreads", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static let alice = "{11111111-1111-4111-8111-111111111111}"

    @Test func readsThreadsAndHidesTheirMirrorNotes() throws {
        let wb = try Workbook(contentsOf: Self.fixture)
        let sheet = wb.sheets[0]
        let a1 = try #require(sheet[cell: "A1"].thread)
        #expect(a1.author == "Alice" && a1.text == "Is this figure final?" && a1.resolved)
        #expect(a1.created == CivilDateTime(iso8601: "2026-09-01T09:30:00"))
        #expect(a1.replies == [CommentThread.Reply("Yes, confirmed with finance.", author: "Bob", created: CivilDateTime(iso8601: "2026-09-01T10:15:00"))])
        let b3 = try #require(sheet[cell: "B3"].thread)
        #expect(b3.author == "Bob" && !b3.resolved && b3.replies.isEmpty)
        #expect(sheet[cell: "A1"].note == nil && sheet[cell: "B3"].note == nil, "the mirror notes are the threads' shadows")
        #expect(sheet[cell: "D5"].note == CellNote("A plain note.", author: "Carol"), "a real note stays")
        #expect(sheet.threads.map(\.ref) == [CellRef("A1")!, CellRef("B3")!])
        #expect(wb.preservationSummary.parts.isEmpty, "the thread parts are the model's: \(wb.preservationSummary.parts)")
        #expect(a1.noteText == "Is this figure final?\n\nBob: Yes, confirmed with finance.")
    }

    @Test func untouchedThreadsAreBytes() throws {
        let source = try Data(contentsOf: Self.fixture)
        let result = try Workbook(contentsOf: Self.fixture).write(as: .xlsx)
        for part in ["xl/threadedComments/threadedComment1.xml", "xl/persons/person.xml", "xl/comments1.xml", "xl/drawings/vmlDrawing1.vml"] {
            #expect(try Package.part(part, of: result.data) == Package.part(part, of: source), Comment(rawValue: part))
        }
        #expect(result.warnings.isEmpty, "\(result.warnings.map(\.message))")
        #expect(try Workbook.read(result.data, format: .xlsx).workbook.sheets[0][cell: "A1"].thread?.replies.count == 1)
    }

    @Test func aChangedThreadRegeneratesThePartsAndKeepsThePeoplesIds() throws {
        var wb = try Workbook(contentsOf: Self.fixture)
        wb.sheets[0][cell: "A1"].thread?.replies.append(CommentThread.Reply("Thanks!", author: "Alice"))
        wb.sheets[0][cell: "E1"].thread = CommentThread("New question", author: "Dana", created: CivilDateTime(iso8601: "2026-09-11T12:00:00"))
        wb.sheets[0][cell: "B3"].thread = nil
        let result = try wb.write(as: .xlsx)
        #expect(result.warnings.isEmpty, "\(result.warnings.map(\.message))")
        let threads = try Package.part("xl/threadedComments/threadedComment1.xml", of: result.data)
        #expect(threads.components(separatedBy: "<threadedComment ").count == 5, "A1 + 2 replies, E1: \(threads)")
        #expect(threads.contains("personId=\"\(Self.alice)\""), "Alice keeps the id the source gave her")
        #expect(threads.contains("ref=\"E1\"") && !threads.contains("ref=\"B3\""))
        let persons = try Package.part("xl/persons/person.xml", of: result.data)
        #expect(persons.contains("displayName=\"Alice\" id=\"\(Self.alice)\"") && persons.contains("displayName=\"Dana\""))
        let comments = try Package.part("xl/comments1.xml", of: result.data)
        #expect(comments.contains("[Threaded comment]") && comments.contains("A plain note.") && comments.contains("Reply:\n    Thanks!"))
        #expect(comments.components(separatedBy: "<comment ").count == 4, "A1 mirror, D5 note, E1 mirror")
        let back = try Workbook.read(result.data, format: .xlsx).workbook.sheets[0]
        #expect(back[cell: "A1"].thread?.replies.map(\.text) == ["Yes, confirmed with finance.", "Thanks!"])
        #expect(back[cell: "E1"].thread?.author == "Dana" && back[cell: "E1"].note == nil && back[cell: "B3"].thread == nil)
        #expect(back[cell: "D5"].note?.text == "A plain note.")
        #expect(back.threads.map(\.thread.text) == wb.sheets[0].threads.map(\.thread.text) && back.threads.map(\.thread.author) == ["Alice", "Dana"])
        #expect(back[cell: "A1"].thread?.replies.last?.created != nil, "a reply made here without a time is written with the time of writing")
    }

    @Test func aNewWorkbookWritesTheThreePartsAndTheirTypes() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        var thread = CommentThread("Please review", author: "Reviewer")
        thread.replies.append(CommentThread.Reply("Done", author: "Author"))
        wb.sheets[0][cell: "A1"].thread = thread
        wb.sheets[0][cell: "C3"].note = CellNote("just a note", author: "Author")
        let result = try wb.write(as: .xlsx)
        #expect(result.warnings.isEmpty, "\(result.warnings.map(\.message))")
        let names = try ZipInspection(data: result.data).entryNames
        #expect(names.contains("xl/threadedComments/threadedComment1.xml") && names.contains("xl/persons/person.xml") && names.contains("xl/comments/comment1.xml"))
        let types = try Package.part("[Content_Types].xml", of: result.data)
        #expect(types.contains("application/vnd.ms-excel.threadedcomments+xml") && types.contains("application/vnd.ms-excel.person+xml"))
        #expect(try Package.part("xl/_rels/workbook.xml.rels", of: result.data).contains("relationships/person"))
        #expect(try Package.part("xl/worksheets/_rels/sheet1.xml.rels", of: result.data).contains("relationships/threadedComment"))
        let back = try Workbook.read(result.data, format: .xlsx).workbook.sheets[0]
        #expect(back[cell: "A1"].thread?.text == thread.text && back[cell: "A1"].thread?.author == "Reviewer" && back[cell: "A1"].thread?.replies.map(\.text) == ["Done"])
        #expect(back[cell: "A1"].note == nil && back[cell: "C3"].note?.text == "just a note")
        #expect(try Workbook.read(result.data, format: .xlsx).workbook.write(as: .xlsx).data.count > 0, "and the file reads and writes again")
    }

    @Test func otherFormatsWriteTheConversationAsANote() throws {
        let wb = try Workbook(contentsOf: Self.fixture)
        let ods = try wb.write(as: .ods)
        #expect(ods.warnings.contains { $0.kind == .substituted && $0.message.contains("2 threaded comment(s) written as notes") }, "\(ods.warnings.map(\.message))")
        let back = try Workbook.read(ods.data, format: .ods).workbook.sheets[0]
        #expect(back[cell: "A1"].note?.text == "Is this figure final?\n\nBob: Yes, confirmed with finance." && back[cell: "A1"].note?.author == "Alice")
        #expect(back[cell: "D5"].note?.text == "A plain note.")
        let numbers = try wb.write(as: .numbers)
        #expect(numbers.warnings.contains { $0.kind == .substituted && $0.message.contains("2 threaded comment(s) written as comments") }, "\(numbers.warnings.map(\.message))")
        var both = wb
        both.sheets[0][cell: "A1"].note = CellNote("my own note", author: "Me")
        let odsBoth = try both.write(as: .ods)
        #expect(odsBoth.warnings.contains { $0.kind == .dropped && $0.message.contains("1 threaded comment(s) dropped: the cell has a note of its own") }, "\(odsBoth.warnings.map(\.message))")
    }

    @Test(.enabled(if: ODSCodecTests.hasLibreOffice, "LibreOffice is not installed at \(ODSCodecTests.soffice)"))
    func libreOfficeShowsTheMirrorOfAThreadWrittenHere() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.sheets[0][cell: "A1"].thread = CommentThread("Visible to older readers", author: "Reviewer")
        let file = Self.tmp.appendingPathComponent("threads.xlsx")
        try wb.write(to: file, as: .xlsx)
        let ods = try ODSImageTests.convert(file, to: "ods")
        let content = try Package.part("content.xml", of: Data(contentsOf: ods))
        #expect(content.contains("<office:annotation") && content.contains("Visible to older readers"), "LibreOffice reads the mirror note: \(content.count) bytes")
    }
}
