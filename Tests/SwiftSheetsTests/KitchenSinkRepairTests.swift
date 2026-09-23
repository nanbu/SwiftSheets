import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

@Suite struct KitchenSinkRepairTests {
    static func part(_ name: String, in data: Data) throws -> String {
        let zip = try ZipInspection(data: data)
        return String(decoding: try #require(zip.entry(named: name)), as: UTF8.self)
    }

    @Test func xlsxHasOneFilterOwnerAndQualifiedLocalName() throws {
        let data = try FormatSupportTests.kitchenSink().write(as: .xlsx).data
        let sheet = try Self.part("xl/worksheets/sheet1.xml", in: data)
        let table = try Self.part("xl/tables/table1.xml", in: data)
        let book = try Self.part("xl/workbook.xml", in: data)
        #expect(!sheet.contains("<autoFilter"))
        #expect(table.contains("<autoFilter ref=\"A1:D9\""))
        #expect(table.contains("<filterColumn colId=\"0\""))
        #expect(table.contains("<sortState ref=\"A2:D9\""))
        #expect(!book.contains("_xlnm._FilterDatabase"))
        #expect(book.contains("name=\"Local\" localSheetId=\"0\">'Data'!$A$1</definedName>"))

        let back = try Workbook(data: data).sheets[0]
        #expect(back.structuredTables.count == 1)
        #expect(back.autoFilter?.address == "A1:D9")
        #expect(back.filterColumns.first?.values == ["East"])
        #expect(back.sortState?.conditions.first?.descending == true)
    }

    @Test func odsKeepsOneDatabaseRangeWithFilterSortAndLocalName() throws {
        let data = try FormatSupportTests.kitchenSink().write(as: .ods).data
        let content = try Self.part("content.xml", in: data)
        #expect(content.contains("table:name=\"Sales\""))
        #expect(!content.contains("__Anonymous_Sheet_DB__0"))
        #expect(content.contains("<table:filter>"))
        #expect(content.contains("<table:sort "))
        #expect(content.contains("table:name=\"Local\" table:base-cell-address=\"$Data.$A$1\""))

        let back = try Workbook(data: data).sheets[0]
        #expect(back.structuredTables.count == 1)
        #expect(back.autoFilter?.address == "A1:D9")
        #expect(back.filterColumns.first?.values == ["East"])
        #expect(back.sortState?.conditions.first?.descending == true)
    }

    @Test func numbersReportsTheUnsupportedFeatures() throws {
        let result = try FormatSupportTests.kitchenSink().write(as: .numbers)
        #expect(result.warnings.contains { $0.message.contains("named table(s) dropped") })
        #expect(result.warnings.contains { $0.message.contains("auto-filter and its sort are dropped") })
        #expect(result.warnings.contains { $0.message.contains("sheet-scoped name(s) dropped") })
        let back = try Workbook(data: result.data)
        #expect(back.sheets["Data"] != nil)
    }

    @Test func distinctSheetFilterStaysIndependentAndFormulaNameIsUnchanged() throws {
        var wb = Workbook()
        var sheet = wb.sheets[0]
        sheet.name = "Data"
        sheet.append([.text("Region"), .text("Qty"), .text("Other")])
        sheet.append([.text("East"), .integer(1), .text("A")])
        sheet.append([.text("West"), .integer(2), .text("B")])
        sheet.addStructuredTable(named: "Sales", over: "A1:B3")
        sheet.autoFilter = CellRange("C1:C3")
        sheet.definedNames["Calc"] = "SUM($A$2:$B$3)"
        wb.sheets[0] = sheet

        let xlsx = try wb.write(as: .xlsx).data
        #expect(try Self.part("xl/worksheets/sheet1.xml", in: xlsx).contains("<autoFilter ref=\"C1:C3\""))
        #expect(try Self.part("xl/tables/table1.xml", in: xlsx).contains("<autoFilter ref=\"A1:B3\""))
        #expect(try Self.part("xl/workbook.xml", in: xlsx).contains(">SUM($A$2:$B$3)</definedName>"))

        let ods = try wb.write(as: .ods).data
        let content = try Self.part("content.xml", in: ods)
        #expect(content.contains("table:name=\"Sales\""))
        #expect(content.contains("__Anonymous_Sheet_DB__0"))
    }

    @Test func conflictingSheetAndTableCriteriaAreReported() throws {
        var wb = FormatSupportTests.kitchenSink()
        wb.sheets[0].structuredTables[0].filterColumns = [FilterColumn(columnOffset: 0, values: ["West"])]
        for format: SheetFormat in [.xlsx, .ods] {
            let result = try wb.write(as: format)
            #expect(result.warnings.contains { $0.message.contains("filters disagree on column 0") }, "\(format)")
        }
    }
}
