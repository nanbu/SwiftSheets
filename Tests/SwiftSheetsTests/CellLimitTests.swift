import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// `ReadOptions.cellLimit` in every reader that holds cells (spec Appendix B.90). Only ODS used to count; a limit set
/// on an XLSX, Numbers or delimited-text read did nothing. A read that stops says so by kind — `truncated`, about the
/// sheet — so a caller refusing oversized files does not match the wording (Appendix B.92).
struct CellLimitTests {
    static func grid(rows: Int, sheets: Int = 1) -> Workbook {
        var wb = Workbook()
        for s in 1..<sheets { wb.addSheet(named: "Sheet\(s + 1)") }
        for i in 0..<sheets {
            for r in 1...rows { wb.sheets[i].append([.integer(r), .integer(r * 2), .text("row \(r)")]) }
        }
        return wb
    }
    static func stops(_ warnings: [ConversionWarning]) -> [ConversionWarning] { warnings.filter { $0.kind == .truncated } }

    @Test(arguments: [SheetFormat.xlsx, .numbers, .csv])
    func aReadStopsAtTheLimitAndSaysWhere(_ format: SheetFormat) throws {
        let data = try Self.grid(rows: 200).write(as: format).data
        let read = try Workbook.read(data, format: format, options: ReadOptions(cellLimit: 100))
        #expect(read.workbook.sheets[0].table.cells.count == 100, "\(format): \(read.workbook.sheets[0].table.cells.count) cells")
        let stops = Self.stops(read.warnings)
        #expect(stops.count == 1, "\(format): \(read.warnings.map(\.message))")
        #expect(stops.first?.subject == .sheets && stops.first?.sheet == read.workbook.sheets[0].name)
        #expect(stops.first?.message.contains("ReadOptions.cellLimit") == true, "\(stops.map(\.message))")
    }

    /// ODS counts the cells its rows and repeats describe (Appendix B.9), so where it stops is its own; the warning it
    /// gives has the same kind, subject and wording as the other readers'.
    @Test func odsSaysSoWithTheSameWarning() throws {
        let data = try Self.grid(rows: 200).write(as: .ods).data
        let read = try Workbook.read(data, format: .ods, options: ReadOptions(cellLimit: 100))
        let stops = Self.stops(read.warnings)
        #expect(stops.count == 1, "\(read.warnings.map(\.message))")
        #expect(stops.first?.subject == .sheets && stops.first?.sheet == read.workbook.sheets[0].name)
        #expect(stops.first?.message.contains("ReadOptions.cellLimit") == true, "\(stops.map(\.message))")
    }

    @Test(arguments: [SheetFormat.xlsx, .numbers, .csv])
    func aLimitTheFileFitsReadsEverythingInSilence(_ format: SheetFormat) throws {
        let data = try Self.grid(rows: 200).write(as: format).data
        let read = try Workbook.read(data, format: format, options: ReadOptions(cellLimit: 600))
        #expect(read.workbook.sheets[0].table.cells.count == 600, "\(format)")
        #expect(Self.stops(read.warnings).isEmpty, "\(format): \(read.warnings.map(\.message))")
    }

    /// One budget for the workbook: sheets read one at a time hold exactly the limit, the first sheet whole and the
    /// second up to what is left.
    @Test func sheetsReadOneAtATimeShareTheBudgetExactly() throws {
        let data = try Self.grid(rows: 200, sheets: 3).write(as: .xlsx).data
        let read = try Workbook.read(data, format: .xlsx, options: ReadOptions(cellLimit: 1_000, concurrency: 1))
        #expect(read.workbook.sheets.map { $0.table.cells.count } == [600, 400, 0])
        #expect(Set(Self.stops(read.warnings).compactMap(\.sheet)) == ["Sheet2", "Sheet3"])
    }

    /// Side by side, the workbook holds at most the limit, and every sheet it stopped is named.
    @Test func sheetsReadSideBySideHoldNoMoreThanTheLimit() throws {
        let data = try Self.grid(rows: 200, sheets: 4).write(as: .xlsx).data
        let read = try Workbook.read(data, format: .xlsx, options: ReadOptions(cellLimit: 1_000, concurrency: 4))
        let counts = read.workbook.sheets.map { $0.table.cells.count }
        #expect(counts.reduce(0, +) <= 1_000, "\(counts)")
        #expect(counts.reduce(0, +) > 1_000 - 4 * CellBudget(limit: 1_000)!.chunk, "\(counts)")
        #expect(Set(Self.stops(read.warnings).compactMap(\.sheet)) == Set(read.workbook.sheets.filter { $0.table.cells.count < 600 }.map(\.name)))
    }
}
