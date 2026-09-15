import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// The part layouts that only Excel itself can author (spec Appendices B.70, B.75 and B.80).
///
/// This is deliberately an opt-in release check rather than a committed binary fixture. Create the workbook by
/// following MAINTENANCE.md, then point `SWIFTSHEETS_EXCEL_GROUND_TRUTH` at it. A successful run writes the file
/// SwiftSheets changed beside the source so Excel can perform the second half of the round-trip check.
@Suite(.serialized) struct ExcelGroundTruthTests {
    static let sourcePath = ProcessInfo.processInfo.environment["SWIFTSHEETS_EXCEL_GROUND_TRUTH"]
    static let sourceExists = sourcePath.map(FileManager.default.fileExists(atPath:)) ?? false
    static let furiganaPath = ProcessInfo.processInfo.environment["SWIFTSHEETS_EXCEL_FURIGANA_GROUND_TRUTH"]
    static let furiganaExists = furiganaPath.map(FileManager.default.fileExists(atPath:)) ?? false

    @Test(.enabled(if: Self.sourceExists,
                   "set SWIFTSHEETS_EXCEL_GROUND_TRUTH to the Excel-made release-check workbook"))
    func readsAndRewritesExcelsOwnAdvancedParts() throws {
        let path = try #require(Self.sourcePath)
        let source = URL(fileURLWithPath: path)
        let read = try Workbook.read(contentsOf: source)
        var workbook = read.workbook
        let sheet = try #require(workbook.sheets.first)

        let thread = try #require(sheet[cell: "A1"].thread)
        #expect(thread.text == "SwiftSheets threaded comment test")
        #expect(thread.replies.map(\.text) == ["SwiftSheets reply test"])
        #expect(sheet[cell: "A1"].note == nil, "Excel's compatibility note is only the thread's mirror")

        #expect(sheet.shapes.isEmpty, "neither SmartArt nor the members of a group are flattened into plain shapes")
        #expect(Set(sheet.preserved.drawingUnmodelled) == ["SmartArt", "a group of shapes"])
        #expect(sheet[cell: "A1"].phonetic?.runs.isEmpty == true,
                "Excel wrote phoneticPr (display settings) but no rPh reading runs")

        workbook.sheets[0][cell: "A1"].thread?.replies.append(
            CommentThread.Reply("Added by SwiftSheets", author: "SwiftSheets"))
        let result = try workbook.write(as: .xlsx)
        #expect(result.warnings.isEmpty, "the untouched drawing and the changed thread are both representable")
        let output = source.deletingPathExtension().appendingPathExtension("roundtrip.xlsx")
        try result.data.write(to: output)
    }

    @Test(.enabled(if: Self.furiganaExists,
                   "set SWIFTSHEETS_EXCEL_FURIGANA_GROUND_TRUTH to an Excel-made workbook containing rPh runs"))
    func excelsOwnFuriganaRunsSurviveARewrite() throws {
        let path = try #require(Self.furiganaPath)
        let source = URL(fileURLWithPath: path)
        let workbook = try Workbook(contentsOf: source)
        let sheet = try #require(workbook.sheets.first)
        let expected: [CellRef: PhoneticText] = sheet.cells.compactMapValues { cell -> PhoneticText? in
            guard let phonetic = cell.phonetic, !phonetic.runs.isEmpty else { return nil }
            return phonetic
        }
        #expect(expected.count == 5, "the Excel-made JIS specimen has five labels with reading spans")
        #expect(expected[CellRef("B2")!]?.runs == [PhoneticText.Run("カンスウ", over: 3..<5)])
        #expect(expected[CellRef("B3")!]?.runs == [
            PhoneticText.Run("ヘンカ", over: 0..<2),
            PhoneticText.Run("ヘンカンマエ", over: 2..<3)
        ])

        let result = try workbook.write(as: .xlsx)
        #expect(result.warnings.isEmpty)
        let output = source.deletingPathExtension().appendingPathExtension("furigana-roundtrip.xlsx")
        try result.data.write(to: output)

        let back = try Workbook(contentsOf: output).sheets[0]
        for (ref, phonetic) in expected { #expect(back[cell: ref].phonetic == phonetic) }
    }
}
