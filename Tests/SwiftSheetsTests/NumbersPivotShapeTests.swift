import Foundation
import Testing
@testable import SheetCore
@testable import SheetNumbers
import SwiftSheets

/// The pivot shapes beyond one field per axis (spec Appendix B.28): several fields on either axis are written as
/// a real Numbers pivot — a nested group tree, one group-by per column-field prefix, each group's subtotal lane
/// in the summary model — and judged by Numbers itself against the documents it wrote for the same workbooks
/// (every shape drawn, zero coordinate assertions, 2026-08-27). Of several summarised values the first is kept
/// and the rest are dropped out loud: the value lanes of a rebuilt pivot share one placeholder id, and a document
/// this writer builds is always rebuilt when Numbers opens it.
///
/// What these tests pin is the half a unit test can see: the stored grid every other reader gets back, and the
/// warnings. The drawing itself is Numbers' verdict, recorded in the appendix.
@Suite struct NumbersPivotShapeTests {
    static func sales() -> Workbook {
        var wb = Workbook()
        var data = wb.sheets[0]
        data.name = "Data"
        data.append([.text("Region"), .text("Product"), .text("Kind"), .text("Qty"), .text("Price")])
        let rows: [(String, String, String, Int, Double)] = [
            ("East", "A", "X", 5, 1.5), ("West", "B", "Y", 7, 2.25), ("North", "A", "X", 3, 4.0), ("East", "B", "Y", 4, 2.0),
            ("West", "A", "X", 5, 3.5), ("North", "B", "Y", 6, 1.25), ("East", "A", "Y", 3, 2.75), ("West", "B", "X", 3, 5.0),
        ]
        for r in rows { data.append([.text(r.0), .text(r.1), .text(r.2), .integer(r.3), .number(Decimal(r.4))]) }
        wb.sheets[0] = data
        wb.addSheet(named: "Pivot")
        return wb
    }
    static let source = CellRange("A1:E9")!

    static func summary(of data: Data) throws -> Table {
        let wb = try Workbook(data: data)
        let table = wb.sheets["Pivot"]?.tables.first { $0.name == "Summary" }
        return try #require(table)
    }

    @Test func twoRowFieldsNestAndKeepTheirLabels() throws {
        var wb = Self.sales()
        _ = wb.addPivotTable(named: "Summary", to: "Pivot", at: CellRef("A1")!, summarizing: Self.source, on: "Data",
                             rows: ["Region", "Product"], values: [("Qty", .sum)])
        let result = try wb.write(as: .numbers)
        #expect(!result.warnings.contains { $0.kind == .dropped && $0.message.contains("pivot") },
                Comment(rawValue: "\(result.warnings.map(\.message))"))
        let t = try Self.summary(of: result.data)
        // one heading row, a label column per row field, a row per leaf — the subtotal rows live in the summary
        // model, which only Numbers draws
        #expect(t[0, 0]?.textValue == "Region")
        #expect(t[0, 1]?.textValue == "Product")
        #expect(t[1, 0]?.textValue == "East")     // the group's label, on its first row only
        #expect(t[1, 1]?.textValue == "A")
        #expect(t[1, 2]?.intValue == 8)
        #expect(t[2, 0] == nil)
        #expect(t[2, 1]?.textValue == "B")
        #expect(t[2, 2]?.intValue == 4)
        #expect(t.nextAppendRow == 7)             // heading + six leaves
    }

    @Test func threeRowFieldsStillNest() throws {
        var wb = Self.sales()
        _ = wb.addPivotTable(named: "Summary", to: "Pivot", at: CellRef("A1")!, summarizing: Self.source, on: "Data",
                             rows: ["Region", "Product", "Kind"], values: [("Qty", .sum)])
        let t = try Self.summary(of: try wb.write(as: .numbers).data)
        #expect(t[0, 2]?.textValue == "Kind")
        #expect(t[1, 0]?.textValue == "East")
        #expect(t[1, 1]?.textValue == "A")
        #expect(t[1, 2]?.textValue == "X")
        #expect(t[1, 3]?.intValue == 5)
    }

    @Test func twoColumnFieldsNestAcrossTheTop() throws {
        var wb = Self.sales()
        _ = wb.addPivotTable(named: "Summary", to: "Pivot", at: CellRef("A1")!, summarizing: Self.source, on: "Data",
                             columns: ["Region", "Product"], values: [("Qty", .sum)])
        let t = try Self.summary(of: try wb.write(as: .numbers).data)
        #expect(t[0, 0]?.textValue == "Region")
        #expect(t[1, 0]?.textValue == "Product")
        #expect(t[0, 1]?.textValue == "East")     // the outer label, over the first lane of its span
        #expect(t[0, 2] == nil)
        #expect(t[1, 1]?.textValue == "A")
        #expect(t[1, 2]?.textValue == "B")
        #expect(t[2, 1]?.intValue == 8)
    }

    @Test func aFieldOnEachAxisAndTwoDeepRowsMix() throws {
        var wb = Self.sales()
        _ = wb.addPivotTable(named: "Summary", to: "Pivot", at: CellRef("A1")!, summarizing: Self.source, on: "Data",
                             rows: ["Region", "Kind"], columns: ["Product"], values: [("Qty", .sum)])
        let t = try Self.summary(of: try wb.write(as: .numbers).data)
        #expect(t[0, 1]?.textValue == "Product")  // the column field's name, in the last label column
        #expect(t[1, 0]?.textValue == "Region")
        #expect(t[1, 1]?.textValue == "Kind")
        #expect(t[2, 0]?.textValue == "East")
        #expect(t[2, 1]?.textValue == "X")
        #expect(t[2, 2]?.intValue == 5)           // East × X × A
    }

    /// Of several summarised values, the first survives and the loss is named — the value lanes of a rebuilt
    /// Numbers pivot share one placeholder id, and every arrangement measured drew one value or none.
    @Test func aSecondValueIsDroppedOutLoud() throws {
        var wb = Self.sales()
        _ = wb.addPivotTable(named: "Summary", to: "Pivot", at: CellRef("A1")!, summarizing: Self.source, on: "Data",
                             rows: ["Region"], values: [("Qty", .sum), ("Price", .sum)])
        let result = try wb.write(as: .numbers)
        #expect(result.warnings.contains { $0.kind == .degraded && $0.message.contains("summarised values dropped") },
                Comment(rawValue: "\(result.warnings.map(\.message))"))
        let t = try Self.summary(of: result.data)
        #expect(t[0, 1]?.textValue == "Sum / Qty")   // the field's own name, minted by addPivotTable
        #expect(t[1, 1]?.intValue == 12)
        #expect(t[0, 2] == nil)                   // no second value lane
    }
}
