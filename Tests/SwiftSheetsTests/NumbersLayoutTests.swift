import Foundation
import Testing
@testable import SheetNumbers
import SwiftSheets

/// Where a table stands on a Numbers canvas (spec Appendix B.85): the exact point is read, and the writer places a
/// table by its point, by a non-default anchor on the default grid, or below the previous table.
@Suite struct NumbersLayoutTests {
    @Test func readsTheExactPointAndTheRoundedAnchor() throws {
        let wb = try Workbook(data: try Data(contentsOf: NumbersCanvasTests.fixtures.appendingPathComponent("canvas-15.numbers")))
        let table = wb.sheets[0].tables[0]
        #expect(table.position != nil)
        #expect(table.anchor == CellRef(row: Int((table.position?.y ?? 0) / 20) + 1, column: Int((table.position?.x ?? 0) / 98) + 1))
    }

    @Test func writesATableAtItsPoint() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "first"
        let i = wb.sheets[0].addTable(named: "Placed", at: CanvasPoint(x: 333, y: 444))
        wb.sheets[0].tables[i]["A1"] = "placed"
        let back = try Workbook(data: try wb.write(as: .numbers).data).sheets[0]
        try #require(back.tables.count == 2)
        #expect(back.tables[1].position == CanvasPoint(x: 333, y: 444))
        #expect(back.tables[1].anchor == CellRef(row: 23, column: 4))
        #expect(back.tables[0].position == CanvasPoint(x: 0, y: 0))
    }

    @Test func aNonDefaultAnchorIsPlacedOnTheDefaultGrid() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "first"
        let i = wb.sheets[0].addTable(named: "Anchored", anchor: CellRef("D12")!)
        wb.sheets[0].tables[i]["A1"] = "x"
        let back = try Workbook(data: try wb.write(as: .numbers).data).sheets[0]
        try #require(back.tables.count == 2)
        #expect(back.tables[1].position == CanvasPoint(x: 3 * 98, y: 11 * 20))
        #expect(back.tables[1].anchor == CellRef("D12"))
    }

    @Test func aTableWithNeitherStacksBelowThePrevious() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "first"
        let i = wb.sheets[0].addTable(named: "Second")
        wb.sheets[0].tables[i]["A1"] = "x"
        let back = try Workbook(data: try wb.write(as: .numbers).data).sheets[0]
        try #require(back.tables.count == 2)
        #expect((back.tables[1].position?.y ?? 0) > 20, "below the first table, not on top of it")
        #expect(back.tables[1].position?.x == 0)
    }

    /// What Numbers laid out comes back at the same point after a pass through the writer.
    @Test func positionsSurviveOurWriter() throws {
        let wb = try Workbook(data: try Data(contentsOf: NumbersCanvasTests.fixtures.appendingPathComponent("pivot-mixed-15.numbers")))
        let back = try Workbook(data: try wb.write(as: .numbers).data)
        for (a, b) in zip(wb.sheets, back.sheets) {
            #expect(a.tables.map(\.position) == b.tables.prefix(a.tables.count).map(\.position), Comment(rawValue: a.name))
        }
    }
}
