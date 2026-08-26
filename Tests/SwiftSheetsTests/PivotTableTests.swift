import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// Pivot tables: the layout part, the cache it reads, and the four things that tie them into the package.
///
/// SwiftSheets lays a pivot table out; the application computes it. Every test here checks the layout and the
/// wiring — the numbers in the body are the reader's business, and the cache says "refresh when opened".
@Suite struct PivotTableTests {

    static func sales() -> Workbook {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws.name = "Data"
        ws.append([.text("Item"), .text("Region"), .text("Qty"), .text("Price")])
        ws.append([.text("apple"), .text("東"), .integer(3), .number(1.5)])
        ws.append([.text("pear"), .text("西"), .integer(5), .number(2.25)])
        ws.append([.text("plum"), .text("東"), .integer(2), .number(4)])
        wb.sheets[0] = ws
        wb.addSheet(named: "Pivot")
        return wb
    }

    // openpyxl: pivot/tests/test_table.py::TestPivotTableDefinition::test_ctor
    // openpyxl: pivot/tests/test_table.py::TestPivotTableDefinition::test_write
    // openpyxl: pivot/tests/test_table.py::TestLocation::test_ctor
    // openpyxl: pivot/tests/test_table.py::TestPageField::test_ctor
    // openpyxl: pivot/tests/test_table.py::TestPivotTableStyle::test_ctor
    // openpyxl: pivot/tests/test_cache.py::TestPivotCacheDefinition::test_write
    // openpyxl: pivot/tests/test_cache.py::TestPivotCacheDefinition::test_path
    // openpyxl: pivot/tests/test_cache.py::TestWorksheetSource::test_ctor
    // openpyxl: pivot/tests/test_cache.py::TestCacheSource::test_ctor
    @Test func aPivotTableOverARangeWritesEveryPartItNeeds() throws {
        var wb = Self.sales()
        let added = wb.addPivotTable(named: "集計", to: "Pivot", at: CellRef("A3")!,
                                     summarizing: CellRange("A1:D4")!, on: "Data",
                                     rows: ["Item"], columns: ["Region"], values: [("Qty", .sum)], filters: ["Price"])
        #expect(added)
        let pivot = wb.sheets[1].pivotTables[0]
        #expect(pivot.rowFields == [0] && pivot.columnFields == [1] && pivot.pageFields.map(\.field) == [3])
        #expect(pivot.dataFields.map(\.field) == [2] && pivot.dataFields[0].function == .sum)
        #expect(pivot.fields.map(\.axis) == [.row, .column, nil, .page])
        #expect(pivot.fields[2].isDataField)

        let data = try wb.data(as: .xlsx)
        let names = try ZipArchive(data: data).entries.keys.sorted()
        #expect(names.contains("xl/pivotTables/pivotTable1.xml"))
        #expect(names.contains("xl/pivotTables/_rels/pivotTable1.xml.rels"))
        #expect(names.contains("xl/pivotCache/pivotCacheDefinition1.xml"))
        #expect(!names.contains("xl/pivotCache/pivotCacheRecords1.xml"), "a generated cache saves no rows")

        let ct = try Package.part("[Content_Types].xml", of: data)
        #expect(ct.contains("/xl/pivotTables/pivotTable1.xml") && ct.contains("/xl/pivotCache/pivotCacheDefinition1.xml"))
        #expect(!ct.contains("_rels/pivotTable1"), "a relationship part is declared by extension, not by override")

        let wbXML = try Package.part("xl/workbook.xml", of: data)
        #expect(wbXML.contains("<pivotCaches><pivotCache cacheId=\"1\" r:id="))
        let wbRels = try Package.part("xl/_rels/workbook.xml.rels", of: data)
        #expect(wbRels.contains("pivotCacheDefinition1.xml"))
        let sheetRels = try Package.part("xl/worksheets/_rels/sheet2.xml.rels", of: data)
        #expect(sheetRels.contains("pivotTable1.xml"))
        #expect(try Package.part("xl/pivotTables/_rels/pivotTable1.xml.rels", of: data).contains("pivotCacheDefinition1.xml"))

        let cache = try Package.part("xl/pivotCache/pivotCacheDefinition1.xml", of: data)
        #expect(cache.contains("refreshOnLoad=\"1\"") && cache.contains("saveData=\"0\""))
        #expect(cache.contains("<worksheetSource ref=\"A1:D4\" sheet=\"Data\"/>"))
        #expect(cache.contains("<cacheField name=\"Item\"") && cache.contains("<cacheField name=\"Price\""))

        let part = try Package.part("xl/pivotTables/pivotTable1.xml", of: data)
        #expect(part.contains("name=\"集計\" cacheId=\"1\""))
        #expect(part.contains("<rowFields count=\"1\"><field x=\"0\"/></rowFields>"))
        #expect(part.contains("<colFields count=\"1\"><field x=\"1\"/></colFields>"))
        #expect(part.contains("<pageFields count=\"1\">"))
        #expect(part.contains("<dataFields count=\"1\">") && part.contains("fld=\"2\""))
    }

    /// A pivot field's name is read; it has to be written too. It was not, so it came home as nothing on every
    /// round trip — found by the cross-format sweep of 2026-08-27 (spec Appendix B.22).
    @Test func aPivotFieldKeepsItsName() throws {
        var wb = Self.sales()
        wb.addPivotTable(named: "P", to: "Pivot", at: CellRef("A1")!, summarizing: CellRange("A1:D4")!, on: "Data",
                         rows: ["Item"], values: [("Qty", .sum)])
        let written = wb.sheets[1].pivotTables[0].fields.map(\.name)
        #expect(written.contains("Item") && written.contains("Qty"), "\(written)")
        let back = try Workbook(data: try wb.data(as: .xlsx)).sheets[1].pivotTables[0].fields.map(\.name)
        #expect(back == written, "the field names did not survive: \(back) vs \(written)")
    }

    /// Everything the layout says survives a round trip, cache and all.
    @Test func theLayoutAndItsCacheReadBack() throws {
        var wb = Self.sales()
        wb.addPivotTable(named: "集計", to: "Pivot", at: CellRef("A3")!, summarizing: CellRange("A1:D4")!, on: "Data",
                         rows: ["Item"], values: [("Qty", .sum), ("Price", .average)])
        let written = wb.sheets[1].pivotTables[0]
        let again = try Workbook(data: try wb.data(as: .xlsx))
        #expect(again.sheets[1].pivotTables.count == 1)
        let read = again.sheets[1].pivotTables[0]
        #expect(read.name == written.name && read.location.ref == written.location.ref)
        #expect(read.rowFields == written.rowFields && read.columnFields == [PivotTable.valuesField])
        #expect(read.dataFields.map { ($0.field, $0.function) }.elementsEqual(written.dataFields.map { ($0.field, $0.function) }, by: ==))
        #expect(read.fields.map(\.axis) == written.fields.map(\.axis))
        #expect(read.cache.sourceRef == CellRange("A1:D4") && read.cache.sourceSheet == "Data")
        #expect(read.cache.fields.map(\.name) == ["Item", "Region", "Qty", "Price"])
        #expect(read.cache.refreshOnLoad)
    }

    /// More than one value needs a place for the captions; one value does not.
    @Test func theValuesFieldIsPlacedOnlyWhenItIsNeeded() throws {
        var one = Self.sales()
        one.addPivotTable(named: "P", to: "Pivot", at: CellRef("A1")!, summarizing: CellRange("A1:D4")!, on: "Data",
                          rows: ["Item"], values: [("Qty", .sum)])
        #expect(one.sheets[1].pivotTables[0].columnFields.isEmpty)

        var two = Self.sales()
        two.addPivotTable(named: "P", to: "Pivot", at: CellRef("A1")!, summarizing: CellRange("A1:D4")!, on: "Data",
                          rows: ["Item"], values: [("Qty", .sum), ("Price", .average)])
        #expect(two.sheets[1].pivotTables[0].columnFields == [PivotTable.valuesField])
        #expect(try Package.part("xl/pivotTables/pivotTable1.xml", of: try two.data(as: .xlsx))
            .contains("<colFields count=\"1\"><field x=\"-2\"/></colFields>"))
    }

    /// A table the format would refuse is reported rather than written.
    @Test func anInvalidPivotTableIsReported() throws {
        var wb = Self.sales()
        var pivot = PivotTable(name: "Bad", location: PivotLocation(ref: CellRange("A1:B2")!),
                               fields: [PivotField(name: "Item")],
                               cache: PivotCache(sourceRef: CellRange("A1:D4")!, sourceSheet: "Data",
                                                 fields: [PivotCacheField(name: "Item")]),
                               dataFields: [PivotDataField(field: 9)])
        pivot.rowFields = [0]
        wb.sheets[1].pivotTables = [pivot]
        let result = try wb.write(as: .xlsx)
        #expect(result.warnings.contains { $0.kind == .dropped && $0.message.contains("summarises a field") })
        #expect(try !ZipArchive(data: result.data).entries.keys.contains { $0.hasPrefix("xl/pivotTables/") })
    }

    /// Naming a column that is not in the header row leaves it out rather than guessing.
    @Test func anUnknownColumnNameIsIgnored() throws {
        var wb = Self.sales()
        let added = wb.addPivotTable(named: "P", to: "Pivot", at: CellRef("A1")!, summarizing: CellRange("A1:D4")!,
                                     on: "Data", rows: ["Item", "Missing"], values: [("Qty", .sum)])
        #expect(added)
        #expect(wb.sheets[1].pivotTables[0].rowFields == [0])
    }

    /// Removing a pivot table takes its parts, its relationships and its cache declaration with it.
    @Test func removingAPivotTableRemovesTheParts() throws {
        var wb = Self.sales()
        wb.addPivotTable(named: "集計", to: "Pivot", at: CellRef("A3")!, summarizing: CellRange("A1:D4")!, on: "Data",
                         rows: ["Item"], values: [("Qty", .sum)])
        var again = try Workbook(data: try wb.data(as: .xlsx))
        again.sheets[1].pivotTables = []
        let out = try again.data(as: .xlsx)
        #expect(try !ZipArchive(data: out).entries.keys.contains { $0.contains("pivot") })
        #expect(try !Package.part("xl/workbook.xml", of: out).contains("pivotCache"))
        #expect(try !Package.part("[Content_Types].xml", of: out).contains("pivot"))
        #expect(try !Package.part("xl/_rels/workbook.xml.rels", of: out).contains("pivot"))
    }

    /// ODF calls a pivot table a data pilot. The layout travels; the numbers are the application's to compute,
    /// exactly as for XLSX.
    @Test func odsWritesADataPilot() throws {
        var wb = Self.sales()
        wb.addPivotTable(named: "集計", to: "Pivot", at: CellRef("A3")!, summarizing: CellRange("A1:D4")!, on: "Data",
                         rows: ["Item"], columns: ["Region"], values: [("Qty", .sum)])
        let result = try wb.write(as: .ods)
        #expect(!result.warnings.contains { $0.kind == .dropped && $0.message.contains("pivot") })
        #expect(result.warnings.contains { $0.kind == .degraded && $0.message.contains("recomputed when the file is opened") })

        let xml = try Package.part("content.xml", of: result.data)
        #expect(xml.contains("<table:data-pilot-tables>"))
        #expect(xml.contains(#"table:source-field-name="Item" table:orientation="row""#))
        #expect(xml.contains(#"table:orientation="data" table:used-hierarchy="-1" table:function="sum""#))

        let back = try Workbook(data: result.data)
        let pivot = try #require(back.sheets["Pivot"]?.pivotTables.first)
        #expect(pivot.name == "集計")
        #expect(pivot.cache.sourceSheet == "Data")
        #expect(pivot.cache.sourceRef == CellRange("A1:D4"))
        #expect(pivot.cache.fields.map(\.name) == wb.sheets["Pivot"]!.pivotTables[0].cache.fields.map(\.name))
        #expect(pivot.rowFields == wb.sheets["Pivot"]!.pivotTables[0].rowFields)
        #expect(pivot.columnFields == wb.sheets["Pivot"]!.pivotTables[0].columnFields)
        #expect(pivot.dataFields.map(\.function) == [.sum])
        #expect(pivot.validationError() == nil)
    }
}
