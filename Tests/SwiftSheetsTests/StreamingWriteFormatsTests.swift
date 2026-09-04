import Foundation
import Testing
@testable import SheetCore
@testable import SheetODS
@testable import SheetXLSX
@testable import SheetNumbers
import SwiftSheets

/// One streaming writer for every format (spec Appendix B.42): rows streamed out through the umbrella
/// `StreamingWriter` come back through the whole-workbook reader and the row-by-row reader alike, whatever the
/// format was; what a format cannot carry is said, never dropped in silence; and the external judges agree.
@Suite struct StreamingWriteFormatsTests {
    static func temporary(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swiftsheets-streamwrite-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    /// Enough rows for three Numbers tiles, and a value of every plain kind; the decimals never happen to be whole
    /// (a whole one comes back as an integer, which is right but not what this compares).
    static let rows = 700
    static func expected(_ r: Int, sheet: Int) -> [CellValue?] {
        [.text("r\(r) s\(sheet)"), .integer(r * sheet), .number(Decimal(r) / 4 + Decimal(string: "0.125")!),
         .bool(r % 2 == 0), r % 5 == 0 ? nil : .text("共通")]
    }

    /// Two sheets; the second wears a number format on its third column.
    @discardableResult
    static func write(_ url: URL, format: SheetFormat? = nil) throws -> StreamingWriter {
        let w = try StreamingWriter(url: url, format: format, sheetName: "First")
        for r in 0..<rows { try w.append(expected(r, sheet: 1)) }
        try w.addSheet(named: "Second")
        for r in 0..<rows {
            var cells = expected(r, sheet: 2).map { v in var c = Cell(); c.value = v; return c }
            cells[2].numberFormat = "0.00"
            try w.append(cells)
        }
        try w.close()
        return w
    }

    /// The same rows, written through the one door in each format, read back both ways.
    @Test(arguments: [SheetFormat.xlsx, .ods, .numbers])
    func rowsStreamedOutComeBackInEveryFormat(_ format: SheetFormat) throws {
        let url = Self.temporary("streamed.\(format.rawValue)")
        let w = try Self.write(url)
        #expect(w.format == format)
        #expect(w.warnings.isEmpty, Comment(rawValue: "\(format): \(w.warnings)"))

        let wb = try Workbook(contentsOf: url)
        #expect(wb.sheets.map(\.name) == ["First", "Second"])
        for r in stride(from: 0, to: Self.rows, by: 89) + [Self.rows - 1] {
            for (c, v) in Self.expected(r, sheet: 1).enumerated() {
                #expect(wb.sheets[0][r, c] == v, Comment(rawValue: "\(format) First r\(r) c\(c): \(String(describing: wb.sheets[0][r, c]))"))
            }
            for (c, v) in Self.expected(r, sheet: 2).enumerated() {
                #expect(wb.sheets[1][r, c] == v, Comment(rawValue: "\(format) Second r\(r) c\(c): \(String(describing: wb.sheets[1][r, c]))"))
            }
        }
        #expect(wb.sheets[1].table.rowCount == Self.rows && wb.sheets[0].table.rowCount == Self.rows)
        #expect(wb.sheets[1][cell: "C1"].numberFormat == "0.00")
        #expect(wb.sheets[0][cell: "C1"].numberFormat == NumberFormat.general)

        let reader = try StreamingReader(contentsOf: url)
        var n = 0
        try reader.forEachRow(inSheet: "Second") { row in
            #expect(row.values(width: 5) == Self.expected(n, sheet: 2), Comment(rawValue: "\(format) row \(n): \(row.values(width: 5))"))
            n += 1
        }
        #expect(n == Self.rows)
    }

    /// The streamed Numbers document keeps the package's invariants: every component has its object, every
    /// reference resolves, the tiles left the writer as they filled and are all there.
    @Test func theStreamedNumbersDocumentIsWhole() throws {
        let url = Self.temporary("whole.numbers")
        try Self.write(url)
        let doc = try NumbersDocument(data: try Data(contentsOf: url))
        #expect(doc.integrityProblems().isEmpty, Comment(rawValue: "\(doc.integrityProblems())"))
        // three tiles per table, each referenced from its table's storage and each a part of its own
        var referenced: [Int] = []
        for sheet in doc.object(NumbersDocument.documentID)?.references("sheets") ?? [] {
            for info in doc.object(sheet)?.references("drawable_infos") ?? [] where doc.typeName(info) == "TST.TableInfoArchive" {
                let store = doc.object(info)?.reference("tableModel").flatMap { doc.object($0) }?.message("base_data_store")
                let tiles = store?.message("tiles")?.messages("tiles").compactMap { $0.reference("tile") } ?? []
                #expect(tiles.count == (Self.rows + 255) / 256, Comment(rawValue: "\(tiles.count) tiles on the table"))
                referenced.append(contentsOf: tiles)
            }
        }
        #expect(referenced.count == 2 * ((Self.rows + 255) / 256))
        let files = Set(referenced.compactMap { doc.locations[$0]?.0 })
        #expect(files.count == referenced.count, "each tile is a part of its own")
        for id in referenced { #expect(doc.typeName(id) == "TST.Tile") }
    }

    /// numbers-parser, the reference reader, sees the streamed rows (skipped when it is not installed).
    static var hasNumbersParser: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", "import numbers_parser"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    @Test(.enabled(if: hasNumbersParser, "numbers-parser is not installed (pip install numbers-parser)"))
    func numbersParserReadsTheStreamedDocument() throws {
        let url = Self.temporary("judged.numbers")
        try Self.write(url)
        let script = """
        import sys, warnings
        warnings.simplefilter("ignore")
        from numbers_parser import Document
        d = Document(sys.argv[1])
        for s in d.sheets:
            t = s.tables[0]
            print(s.name, t.num_rows, t.num_cols, repr(t.cell(0, 0).value), t.cell(699, 1).value, t.cell(1, 2).value, t.cell(2, 3).value, repr(t.cell(5, 4).value))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", script, url.path]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, Comment(rawValue: out))
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.count == 2, Comment(rawValue: out))
        #expect(lines.first == "First 700 5 'r0 s1' 699.0 0.375 True None", Comment(rawValue: out))
        #expect(lines.last == "Second 700 5 'r0 s2' 1398.0 0.375 True None", Comment(rawValue: out))
    }

    /// LibreOffice reads the streamed ODS and writes it back as XLSX with the values intact (skipped without it).
    @Test(.enabled(if: ODSCodecTests.hasLibreOffice, "LibreOffice is not installed"))
    func libreOfficeReadsTheStreamedODS() throws {
        let url = Self.temporary("judged.ods")
        try Self.write(url)
        let outdir = url.deletingLastPathComponent().appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outdir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ODSCodecTests.soffice)
        p.arguments = ["-env:UserInstallation=file://\(outdir.path)/profile", "--headless", "--convert-to", "xlsx", "--outdir", outdir.path, url.path]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let converted = outdir.appendingPathComponent("judged.xlsx")
        try #require(FileManager.default.fileExists(atPath: converted.path), Comment(rawValue: "LibreOffice did not convert: \(log)"))
        let wb = try Workbook(contentsOf: converted)
        #expect(wb.sheets.map(\.name) == ["First", "Second"])
        #expect(wb.sheets[1][699, 0] == .text("r699 s2") && wb.sheets[1][699, 1] == .integer(1398))
        #expect(wb.sheets[1][1, 2] == .number(Decimal(string: "0.375")!) && wb.sheets[0][2, 3] == .bool(true))
        #expect(wb.sheets[1][cell: "C1"].numberFormat == "0.00")
    }

    /// A Numbers tile is written at one width: the table is as wide as its widest row, a wider row inside the
    /// first tile is fine, and a row wider than the tiles already written is refused, out loud.
    @Test func aRowWiderThanTheWrittenTilesIsRefusedByNumbers() throws {
        let url = Self.temporary("wide.numbers")
        let w = try NumbersStreamingWriter(url: url, sheetName: "S")
        try w.append([.integer(1), .integer(2)])
        try w.append([.integer(1), .integer(2), .integer(3), .integer(4)])   // wider, still in the first tile
        for r in 2..<300 { try w.append([.integer(r)]) }
        #expect(throws: SheetError.self) { try w.append([.integer(1), .integer(2), .integer(3), .integer(4), .integer(5)]) }
        try w.append([.integer(300), .integer(0), .integer(0), .integer(0)])   // as wide as the table: fine
        try w.close()
        let wb = try Workbook(contentsOf: url)
        #expect(wb.sheets[0].table.columnCount == 4)
        #expect(wb.sheets[0][1, 3] == .integer(4) && wb.sheets[0][300, 0] == .integer(300))
    }

    /// Delimited text holds one sheet; asking for a second is refused, and the first is still written.
    @Test func delimitedTextRefusesASecondSheet() throws {
        let url = Self.temporary("one.csv")
        let w = try StreamingWriter(url: url)
        #expect(w.format == .csv)
        try w.append([.text("a"), .integer(1)])
        #expect(throws: SheetError.self) { try w.addSheet(named: "Two") }
        try w.append([.text("b"), .integer(2)])
        try w.close()
        let wb = try Workbook(contentsOf: url)
        #expect(wb.sheets[0][1, 0] == .text("b"))
    }

    /// The format follows the extension the way `Workbook.write(to:)` decides it, or the argument; a path with
    /// neither is XLSX.
    @Test func theFormatFollowsTheExtensionOrTheArgument() throws {
        let tsv = try StreamingWriter(url: Self.temporary("t.tsv"))
        #expect(tsv.format == .csv)
        try tsv.close()
        let bare = try StreamingWriter(url: Self.temporary("bare"))
        #expect(bare.format == .xlsx)
        try bare.close()
        let datURL = Self.temporary("t.dat")
        let dat = try StreamingWriter(url: datURL, format: .ods, sheetName: "X")
        #expect(dat.format == .ods)
        try dat.append([.integer(7)])
        try dat.close()
        let ods = try Workbook.read(contentsOf: datURL)   // the bytes say ODS whatever the extension
        #expect(ods.workbook.sheets[0].name == "X" && ods.workbook.sheets[0]["A1"] == .integer(7))
        let macro = Self.temporary("m.xlsm")
        let xlsm = try StreamingWriter(url: macro)
        #expect(xlsm.format == .xlsm)
        try xlsm.append([.text("macro-enabled, no macros")])
        try xlsm.close()
        let read = try Workbook.read(contentsOf: macro)
        #expect(read.workbook.preserved.sourceFormat == .xlsm)
        #expect(read.workbook.sheets[0]["A1"] == .text("macro-enabled, no macros"))
    }

    /// What the Numbers writer cannot carry is reported: a formula goes out as its cached value, a link and a note
    /// are dropped — each counted, none silent. The XLSX writer carries all of them and says nothing.
    @Test func whatAFormatCannotCarryIsSaid() throws {
        func row() -> [Cell] {
            var a = Cell(); a.value = .formula(FormulaExpr.parse("=1+1"), cached: .integer(2))
            var b = Cell(); b.value = .text("link"); b.hyperlink = Hyperlink(target: "https://example.com")
            var c = Cell(); c.value = .integer(3); c.comment = CellNote("note", author: "t")
            var d = Cell(); d.value = .formula(FormulaExpr.parse("=A1*2"), cached: nil)
            return [a, b, c, d]
        }
        let numbers = Self.temporary("said.numbers")
        let n = try StreamingWriter(url: numbers, sheetName: "S")
        try n.append(row()); try n.append(row())
        try n.close()
        let said = n.warnings.map(\.message).joined(separator: " | ")
        #expect(said.contains("4 formula(s)") && said.contains("2 without one"), Comment(rawValue: said))
        #expect(said.contains("2 link(s) dropped") && said.contains("2 note(s) dropped"), Comment(rawValue: said))
        let wb = try Workbook(contentsOf: numbers)
        #expect(wb.sheets[0]["A1"] == .integer(2) && wb.sheets[0]["D1"] == nil && wb.sheets[0]["C2"] == .integer(3))

        let xlsx = Self.temporary("said.xlsx")
        let x = try StreamingWriter(url: xlsx, sheetName: "S")
        try x.append(row())
        try x.close()
        #expect(x.warnings.isEmpty)
        let back = try Workbook(contentsOf: xlsx)
        #expect(back.sheets[0]["A1"] == .formula(FormulaExpr.parse("=1+1"), cached: .integer(2)))
    }

    /// A sheet that got no rows is still a table in every format.
    @Test(arguments: [SheetFormat.xlsx, .ods, .numbers])
    func aSheetWithNoRowsIsStillASheet(_ format: SheetFormat) throws {
        let url = Self.temporary("empty.\(format.rawValue)")
        let w = try StreamingWriter(url: url, sheetName: "Empty")
        try w.addSheet(named: "Also")
        try w.close()
        let wb = try Workbook(contentsOf: url)
        #expect(wb.sheets.map(\.name) == ["Empty", "Also"])
        #expect(wb.sheets[0].table.cells.isEmpty && wb.sheets[1].table.cells.isEmpty)
    }
}
