import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// The sheets of an XLSX workbook parsed side by side (spec Appendix B.41): the same model as one at a time, the
/// warnings in sheet order, the first failure in sheet order — and a gate that decides on its own only when the
/// caller says nothing.
@Suite struct ParallelReadTests {
    /// Sheets that touch what a parse shares: shared strings (one common text), the style caches (two formats),
    /// formulas, links, notes and a merge.
    static func workbook(sheets: Int, rows: Int) -> Workbook {
        var out: [Sheet] = []
        for s in 1...sheets {
            var sheet = Sheet(name: "S\(s)")
            for r in 0..<rows {
                sheet.append([.text("row \(r) of \(s)"), .integer(r * s), .number(Decimal(r) / 8),
                              .formula(FormulaExpr.parse("=B\(r + 1)*2"), cached: .integer(r * s * 2)),
                              .bool(r % 2 == 0), .text(r % 3 == 0 ? "共通" : "個別 \(s)")])
            }
            sheet[cell: "C1"].numberFormat = "0.000"
            sheet[cell: "B2"].numberFormat = "yyyy-mm-dd"
            sheet[cell: "A1"].hyperlink = Hyperlink(target: "https://example.com/\(s)")
            sheet[cell: "A2"].comment = CellNote("note on sheet \(s)", author: "t")
            sheet.merge("D1:E2")
            out.append(sheet)
        }
        return Workbook(sheets: out)
    }

    /// Read one at a time and read side by side agree, cell for cell and warning for warning.
    @Test func sideBySideReadsTheSameWorkbook() throws {
        let data = try Self.workbook(sheets: 6, rows: 200).data(as: .xlsx)
        let serial = try Workbook.read(data, format: .xlsx, options: ReadOptions(concurrency: 1))
        let parallel = try Workbook.read(data, format: .xlsx, options: ReadOptions(concurrency: 6))
        #expect(parallel.workbook == serial.workbook)
        #expect(parallel.warnings == serial.warnings)
        #expect(parallel.workbook.sheets.map(\.name) == (1...6).map { "S\($0)" })
        #expect(parallel.workbook.sheets[3]["B5"] == .integer(16))            // row 4 of sheet 4
        #expect(parallel.workbook.sheets[5][cell: "C1"].numberFormat == "0.000")
        #expect(parallel.workbook.sheets[5][cell: "A2"].comment?.text == "note on sheet 6")
        #expect(parallel.workbook.sheets[0][cell: "A1"].hyperlink?.target == "https://example.com/1")
    }

    /// The warnings come in sheet order whichever sheet finished first: a selection that leaves four sheets out
    /// reports them in the order the workbook lists them, every time.
    @Test func warningsKeepSheetOrder() throws {
        let data = try Self.workbook(sheets: 5, rows: 40).data(as: .xlsx)
        for _ in 0..<5 {
            let result = try Workbook.read(data, format: .xlsx, options: ReadOptions(sheets: .named(["S3"]), concurrency: 5))
            let left = result.warnings.filter { $0.message.contains("left out by ReadOptions.sheets") }.map(\.sheet)
            #expect(left == ["S1", "S2", "S4", "S5"])
            #expect(result.workbook.sheets.map(\.name) == ["S1", "S2", "S3", "S4", "S5"])
            #expect(result.workbook.sheets[2]["B3"] == .integer(6))          // row 2 of sheet 3 (B2 wears the date format)
            #expect(result.workbook.sheets[0].preserved.isUnread && !result.workbook.sheets[2].preserved.isUnread)
        }
    }

    /// Two sheets missing their parts at once: the failure thrown is the earlier one in the workbook's order,
    /// every time, whichever the parsers reached first.
    @Test func theFirstFailureInSheetOrderIsTheOneThrown() throws {
        let data = try Self.workbook(sheets: 4, rows: 40).data(as: .xlsx)
        let zip = try ZipArchive(data: data)
        let writer = ZipWriter()
        for name in zip.entries.keys.sorted() where !name.hasSuffix("sheet2.xml") && !name.hasSuffix("sheet4.xml") {
            writer.add(name, try zip.read(name))
        }
        let broken = writer.finish()
        for _ in 0..<5 {
            do {
                _ = try Workbook.read(broken, format: .xlsx, options: ReadOptions(concurrency: 4))
                Issue.record("a workbook missing two sheet parts was read")
            } catch let error as SheetError {
                #expect("\(error)".contains("sheet2"), Comment(rawValue: "\(error)"))
            }
        }
    }

    /// The gate: nothing to decide for one sheet; the caller's number wins, capped at the sheets there are and
    /// never below one; left unsaid, side by side only past the size threshold, and never more than the cores.
    @Test func theGateFollowsTheSizeAndTheCallersNumber() {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let small = [100_000, 200_000], big = [3 << 20, 2 << 20]
        #expect(WorkbookReader.concurrency(parsedBytes: [], options: ReadOptions()) == 1)
        #expect(WorkbookReader.concurrency(parsedBytes: [5 << 20], options: ReadOptions()) == 1)
        #expect(WorkbookReader.concurrency(parsedBytes: small, options: ReadOptions()) == 1)
        #expect(WorkbookReader.concurrency(parsedBytes: big, options: ReadOptions()) == min(cores, 2))
        #expect(WorkbookReader.concurrency(parsedBytes: Array(repeating: 1 << 20, count: 32), options: ReadOptions()) == min(cores, 32))
        #expect(WorkbookReader.concurrency(parsedBytes: big, options: ReadOptions(concurrency: 1)) == 1)
        #expect(WorkbookReader.concurrency(parsedBytes: small, options: ReadOptions(concurrency: 2)) == 2)
        #expect(WorkbookReader.concurrency(parsedBytes: small, options: ReadOptions(concurrency: 8)) == 2)
        #expect(WorkbookReader.concurrency(parsedBytes: small, options: ReadOptions(concurrency: 0)) == 1)
        #expect(WorkbookReader.concurrency(parsedBytes: [1, 2, 3], options: ReadOptions(concurrency: -3)) == 1)
    }

    /// The style caches are filled before any sheet starts, and an xf that does not exist is answered with the
    /// default and never cached — so a sheet that names one cannot make a parser running beside it write.
    @Test func theStyleCachesAreFilledUpFrontAndNeverGrowForAMissingXF() throws {
        let data = try Self.workbook(sheets: 1, rows: 3).data(as: .xlsx)
        let zip = try ZipArchive(data: data)
        let styles = StylesParser()
        try styles.run(try zip.read("xl/styles.xml"), part: "xl/styles.xml")
        styles.prefill()
        let past = styles.cellXfs.count + 7
        #expect(styles.numericKind(past) == .plain)
        #expect(styles.sharedStyle(past) == nil)
        #expect(styles.numericKind(1) != .plain || styles.numericKind(2) != .plain, "the two formats the sheet uses are known")
    }
}
