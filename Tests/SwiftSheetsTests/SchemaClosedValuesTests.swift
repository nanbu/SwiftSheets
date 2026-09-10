import Foundation
import Testing
@testable import SheetXLSX
@testable import SheetCore
@testable import SwiftSheets

/// Spec Appendix B.66: five properties whose OOXML schema closes the set are enumerations. A file that carries a
/// name outside the list is invalid, and the reader neither guesses nor drops it in silence — the value goes, and
/// the sheet's unmodelled flag (or a read warning) says so.
@Suite struct SchemaClosedValuesTests {
    @Test func anUnknownDynamicFilterTypeIsDroppedAndFlagged() throws {
        let sheet = try parseSheet("""
            <autoFilter ref="A1:D9"><filterColumn colId="3"><dynamicFilter type="bogus" val="2.5"/></filterColumn></autoFilter>
            """)
        #expect(sheet.filterColumns.first?.dynamicFilter == nil, "a type the schema does not name is not carried")
        #expect(sheet.hasUnmodelledFilters, "…and the sheet says a filter was not modelled")
        let known = try parseSheet("""
            <autoFilter ref="A1:D9"><filterColumn colId="3"><dynamicFilter type="aboveAverage" val="2.5"/></filterColumn></autoFilter>
            """)
        #expect(known.filterColumns.first?.dynamicFilter?.kind == .aboveAverage && !known.hasUnmodelledFilters)
    }

    @Test func anUnknownTimePeriodIsDroppedAndFlagged() throws {
        let sheet = try parseSheet("""
            <conditionalFormatting sqref="A1:A9"><cfRule type="timePeriod" priority="1" timePeriod="bogus"/></conditionalFormatting>
            """)
        #expect(sheet.conditionalFormatting.first?.rules.first?.timePeriod == nil)
        #expect(sheet.hasUnmodelledConditionalFormats)
        let known = try parseSheet("""
            <conditionalFormatting sqref="A1:A9"><cfRule type="timePeriod" priority="1" timePeriod="lastWeek"/></conditionalFormatting>
            """)
        #expect(known.conditionalFormatting.first?.rules.first?.timePeriod == .lastWeek && !known.hasUnmodelledConditionalFormats)
    }

    @Test func anUnknownTotalsRowFunctionIsDroppedWithAWarning() throws {
        var wb = StructuredTableTests.sales()
        wb.sheets[0].addStructuredTable(named: "Sales", over: CellRange("A1:C3")!)
        wb.sheets[0].structuredTables[0].columns[1].totalsRowFunction = .sum
        let plain = try wb.write(as: .xlsx).data
        let part = try Package.part("xl/tables/table1.xml", of: plain)
        #expect(part.contains("totalsRowFunction=\"sum\""))
        let broken = try Package.repacking(plain, replacing: "xl/tables/table1.xml",
                                           with: Data(part.replacingOccurrences(of: "totalsRowFunction=\"sum\"", with: "totalsRowFunction=\"bogus\"").utf8))
        let again = try Workbook(data: broken)
        #expect(again.sheets[0].structuredTables[0].columns[1].totalsRowFunction == nil)
        #expect(again.readWarnings.contains { $0.kind == .dropped && $0.subject == .tables && $0.message.contains("bogus") },
                "the dropped function is reported, not lost in silence: \(again.readWarnings)")
        let sameAsWritten = try Workbook(data: plain)
        #expect(sameAsWritten.sheets[0].structuredTables[0].columns[1].totalsRowFunction == .sum && !sameAsWritten.readWarnings.contains { $0.subject == .tables })
    }
}
