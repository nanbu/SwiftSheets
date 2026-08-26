import Foundation
import Testing
@testable import SheetCore
@testable import SheetNumbers
import SwiftSheets

/// A cell that holds **no value and a style** is how a sheet draws: a Gantt bar, a calendar's weekend column, a
/// legend swatch, a banded background are all colour and nothing else. The model keeps such a cell — `isBlank` is
/// false as soon as the style is not the default — and the reader has always brought it back. The Numbers writer
/// dropped it: the cell loop skipped a cell with no value before it ever reached the style, so the fill went out
/// with no record and no warning, and the drawing arrived blank.
///
/// Found from Stream (2026-08-26), whose Gantt chart draws its day grid in exactly these cells: 66 of a 70-row
/// sample's cells vanished, and the LibreOffice render of the result was an empty grid. `.xlsx` and `.ods` were
/// never affected — this suite pins the Numbers side to the behaviour they already had.
///
/// Judges: our own reader (here), numbers-parser through `Tests/NumbersParity/verify_valueless_cells.py`, and
/// Numbers 15.3.1 itself — which opens the result clean and draws the whole staircase, where before the fix it
/// drew an empty grid.
@Suite struct NumbersValuelessCellTests {

    /// Three cells that differ only in what they hold: a value, the empty string, nothing at all. All three carry
    /// the same fill, so all three must come back with it. The middle one is the workaround Stream had to adopt;
    /// the last one is the defect.
    @Test func aFillSurvivesWhateverTheCellHolds() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws[cell: "A1"].value = .text("x")
        ws[cell: "A2"].value = .text("")
        // A3 is left without a value on purpose — only the fill below gives it a reason to exist.
        for ref in ["A1", "A2", "A3"] { ws.style(ref) { $0.fill = .solid(Color(hex: "4472C4")) } }
        wb.sheets[0] = ws

        let result = try wb.write(as: .numbers)
        let back = try NumbersCodec.read(result.data).workbook.sheets[0]

        for ref in ["A1", "A2", "A3"] {
            #expect(back.style(ref).fill.foregroundColor == Color(hex: "FF4472C4"),
                    Comment(rawValue: "\(ref) lost its fill: \(back.style(ref).fill)"))
        }
        #expect(back["A1"] == .text("x"))
    }

    /// The drawing case in miniature: a block of cells with nothing but colour, as a Gantt bar is drawn. Every one
    /// of them must be in the document that comes back.
    @Test func aBlockOfColourOnlyCellsIsWrittenWhole() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws["A1"] = "task"                                  // one real value, as a real sheet has
        for row in 1...8 {
            for col in 0..<10 {
                ws.style(at: CellRef(row: row, col: col)) { $0.fill = .solid(Color(hex: "70AD47")) }
            }
        }
        wb.sheets[0] = ws

        let result = try wb.write(as: .numbers)
        let reread = try NumbersCodec.read(result.data)
        let back = reread.workbook.sheets[0]

        var missing: [String] = []
        for row in 1...8 {
            for col in 0..<10 {
                let ref = CellRef(row: row, col: col)
                if back.style(at: ref).fill.foregroundColor != Color(hex: "FF70AD47") { missing.append(ref.a1) }
            }
        }
        #expect(missing.isEmpty, Comment(rawValue: "\(missing.count) of 80 painted cells came back unpainted: \(missing.prefix(8))"))
    }

    /// The far corner. A colour-only cell in the last row and column is the one a bound computed from "cells that
    /// hold something" would clip, so the round trip is asked for it by itself.
    @Test func aColourOnlyCellAtTheEdgeIsKept() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws["A1"] = "corner"
        ws.style("F9") { $0.fill = .solid(Color(hex: "FFC000")) }
        wb.sheets[0] = ws

        let back = try NumbersCodec.read(try wb.write(as: .numbers).data).workbook.sheets[0]
        #expect(back.style("F9").fill.foregroundColor == Color(hex: "FFFFC000"))
    }

    /// A border with no value is the same kind of cell — a ruled but empty box — and goes the same way.
    @Test func aBorderOnlyCellIsKept() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws["A1"] = "x"
        ws.style("C3") { $0.border.bottom = Side(style: .thin, color: Color(hex: "FF0000")) }
        wb.sheets[0] = ws

        let back = try NumbersCodec.read(try wb.write(as: .numbers).data).workbook.sheets[0]
        #expect(back.style("C3").border.bottom.style == .thin)
        #expect(back.style("C3").border.bottom.color == Color(hex: "FFFF0000"))
    }

    /// The other half of the promise: writing a value-less styled cell must not turn every untouched cell into a
    /// record. A cell nothing was ever asked of is not in the model, and the document must not grow one for it —
    /// otherwise the table's rectangle, not its contents, decides the file size.
    @Test func untouchedCellsStillCostNothing() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws["A1"] = "only me"
        ws["E5"] = "far corner"     // the 23 cells of the rectangle between them were never given anything
        wb.sheets[0] = ws
        #expect(ws.cells.count == 2, "the model itself should hold two cells")

        let result = try wb.write(as: .numbers)
        let back = try NumbersCodec.read(result.data).workbook.sheets[0]
        #expect(back.cells.count == 2, Comment(rawValue: "untouched cells gained records: \(back.cells.keys.map(\.a1).sorted())"))
    }

    /// Nothing is dropped, so nothing is reported. The library's promise runs both ways — a document that lost
    /// nothing must not collect warnings that say it did.
    @Test func aPaintedSheetEarnsNoWarnings() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws["A1"] = "task"
        for row in 1...4 { ws.style(at: CellRef(row: row, col: 2)) { $0.fill = .solid(Color(hex: "70AD47")) } }
        wb.sheets[0] = ws

        let result = try wb.write(as: .numbers)
        #expect(result.warnings.isEmpty, Comment(rawValue: "\(result.warnings.map(\.message))"))
    }

    static let outDir: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("swiftsheets-valueless-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    /// Writes the document the second judge reads. A Gantt in miniature: a label column with values, and bars made
    /// of cells that carry nothing but colour — the shape that came out empty. Read back by
    /// `Tests/NumbersParity/verify_valueless_cells.py` with numbers-parser, which shares no code with our reader.
    @Test func writesTheSampleTheOtherJudgeReads() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws.name = "Gantt"
        ws["A1"] = "task"; ws["B1"] = "start"
        for (row, name) in ["設計", "実装", "検証"].enumerated() {
            ws[cell: CellRef(row: row + 1, col: 0)].value = .text(name)
            for col in (2 + row)...(4 + row) {                       // the bar: colour, no value
                ws.style(at: CellRef(row: row + 1, col: col)) { $0.fill = .solid(Color(hex: "70AD47")) }
            }
        }
        ws.style("C1") { $0.font.size = 11; $0.font.bold = true }    // the 11pt case, alongside the bars
        wb.sheets[0] = ws

        let result = try wb.write(as: .numbers)
        #expect(result.warnings.isEmpty, Comment(rawValue: "\(result.warnings.map(\.message))"))
        try result.data.write(to: Self.outDir.appendingPathComponent("valueless-cells.numbers"))
    }

    /// The document has to stay one Numbers can open: the records written for these cells are referenced from the
    /// tile like any other, and the style objects they name have to exist.
    @Test func theDocumentStaysIntact() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws["A1"] = "task"
        for row in 1...6 { ws.style(at: CellRef(row: row, col: 1)) { $0.fill = .solid(Color(hex: "4472C4")) } }
        wb.sheets[0] = ws

        let doc = try NumbersDocument(data: try wb.write(as: .numbers).data)
        #expect(doc.integrityProblems().isEmpty, "\(doc.integrityProblems().prefix(5))")
    }
}

/// The second defect found from Stream on the same day (Appendix B.20). The writer skipped a font size equal to
/// `Font.default.size` — Calibri 11, Excel's default — on the reasoning that a default need not be written. But the
/// Numbers template it writes into defaults to **HelveticaNeue 10**, so what went unwritten was not inherited back:
/// a cell asking for exactly 11pt was drawn a point small, while 10pt and 12pt came out right.
@Suite struct NumbersFontSizeTests {

    /// Every size a styled cell states survives — including the one that happens to equal the model's own default.
    /// The fill is what makes the style a style; see `elevenPointAloneIsTheDefaultStyle` for why it has to be here.
    @Test(arguments: [8.0, 10.0, 11.0, 12.0, 14.0, 18.0])
    func aStatedFontSizeIsWritten(_ size: Double) throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws["A1"] = "sized"
        ws.style("A1") { $0.font.size = size; $0.fill = .solid(Color(hex: "EEEEEE")) }
        wb.sheets[0] = ws

        let back = try NumbersCodec.read(try wb.write(as: .numbers).data).workbook.sheets[0]
        #expect(back.style("A1").font.size == size,
                Comment(rawValue: "\(size)pt came back as \(String(describing: back.style("A1").font.size))"))
    }

    /// The regression in the shape it was found: 11 against its neighbours, in one document.
    @Test func elevenPointIsNotSwallowedByItsNeighbours() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        for (i, size) in [10.0, 11.0, 12.0].enumerated() {
            let ref = CellRef(row: i, col: 0)
            ws[cell: ref].value = .text("\(size)")
            ws.style(at: ref) { $0.font.size = size; $0.font.bold = true }
        }
        wb.sheets[0] = ws

        let back = try NumbersCodec.read(try wb.write(as: .numbers).data).workbook.sheets[0]
        #expect(back.style("A1").font.size == 10)
        #expect(back.style("A2").font.size == 11)   // this one used to come back nil, and Numbers drew it at 10
        #expect(back.style("A3").font.size == 12)
    }

    /// Where the fix deliberately stops. A style whose only content is "11pt" **is** `CellStyle.default` — the model
    /// cannot tell "the caller asked for 11" from "the caller said nothing" — so the cell is written unstyled and
    /// takes the template's HelveticaNeue 10, as every plain cell does. Making it write 11 would mean stamping an
    /// explicit Calibri 11 onto every cell of every document this library writes; that is a change of look for all
    /// output, not a bug fix, so it is the owner's to make. Pinned here so it stays a decision.
    @Test func elevenPointAloneIsTheDefaultStyle() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws["A1"] = "plain"
        ws.style("A1") { $0.font.size = 11 }
        wb.sheets[0] = ws
        #expect(ws.style("A1") == .default, "a style saying only 11pt is the model's default style")

        let back = try NumbersCodec.read(try wb.write(as: .numbers).data).workbook.sheets[0]
        #expect(back.style("A1").font.size == 10, "an unstyled cell inherits the Numbers template")
    }
}

/// The third of the same family (Appendix B.21). The writer compared the *face* against `Font.default.name` —
/// Calibri, Excel's default — and skipped it when equal, exactly as it did with the size. The Numbers template's
/// own default face is **HelveticaNeue**, so a cell that asked for Calibri was drawn in HelveticaNeue and said
/// nothing about it. What the model states about the face is now always written.
///
/// Note what this does *not* claim: that the reader's machine has the face. Calibri is not installed on the Mac
/// this was measured on, and Numbers substitutes when a face is missing — as any reader does. Writing the name the
/// model gave is the library's whole job here; choosing a substitute is the reader's.
@Suite struct NumbersFontNameTests {

    /// Every face the model states survives the round trip — Calibri included, which is the one that used to go.
    /// The fill is what makes the style a style; see `calibriAloneIsTheDefaultStyle` for why it has to be there.
    @Test(arguments: ["Calibri", "Georgia", "Arial", "Verdana", "Helvetica Neue"])
    func aStatedFontNameIsWritten(_ name: String) throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws["A1"] = "faced"
        ws.style("A1") { $0.font.name = name; $0.fill = .solid(Color(hex: "EEEEEE")) }
        wb.sheets[0] = ws

        let back = try NumbersCodec.read(try wb.write(as: .numbers).data).workbook.sheets[0]
        #expect(back.style("A1").font.name == name,
                Comment(rawValue: "\(name) came back as \(String(describing: back.style("A1").font.name))"))
    }

    /// The regression in the shape it was found: Calibri beside a face that was never affected, in one document.
    @Test func calibriIsNotSwallowedByItsNeighbours() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        for (i, name) in ["Calibri", "Georgia"].enumerated() {
            let ref = CellRef(row: i, col: 0)
            ws[cell: ref].value = .text(name)
            ws.style(at: ref) { $0.font.name = name; $0.font.bold = true }
        }
        wb.sheets[0] = ws

        let back = try NumbersCodec.read(try wb.write(as: .numbers).data).workbook.sheets[0]
        #expect(back.style("A1").font.name == "Calibri")   // used to come back nil, drawn as HelveticaNeue
        #expect(back.style("A2").font.name == "Georgia")
    }

    /// Where this fix stops, for the same reason the size one does: a style whose only content is "Calibri" **is**
    /// `CellStyle.default`, so the cell is written unstyled and takes the template's own face. The model cannot
    /// tell "the caller asked for Calibri" from "the caller said nothing", and stamping every plain cell of every
    /// document with an explicit Calibri is a change of look, not a bug fix. Pinned so it stays a decision.
    @Test func calibriAloneIsTheDefaultStyle() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws["A1"] = "plain"
        ws.style("A1") { $0.font.name = "Calibri" }
        wb.sheets[0] = ws
        #expect(ws.style("A1") == .default, "a style saying only Calibri is the model's default style")

        let back = try NumbersCodec.read(try wb.write(as: .numbers).data).workbook.sheets[0]
        #expect(back.style("A1").font.name == "Helvetica Neue", "an unstyled cell inherits the Numbers template")
    }

    /// A face and a size together, which is what a real heading says. Both used to be dropped when they matched
    /// Excel's defaults; both must survive now.
    @Test func calibriElevenTogetherSurvive() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws["A1"] = "heading"
        ws.style("A1") { $0.font.name = "Calibri"; $0.font.size = 11; $0.fill = .solid(Color(hex: "DDDDDD")) }
        wb.sheets[0] = ws

        let back = try NumbersCodec.read(try wb.write(as: .numbers).data).workbook.sheets[0]
        #expect(back.style("A1").font.name == "Calibri")
        #expect(back.style("A1").font.size == 11)
    }
}
