import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// `wb.externalLinks` — the other workbooks the formulas refer to (spec Appendix B.78): read from OOXML's link
/// parts, derived from the documents ODS formulas name, never resolved, carried as bytes on a same-format write.
struct ExternalLinkTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let xlsx = fixtures.appendingPathComponent("preservation/external-links.xlsx")
    static let ods = fixtures.appendingPathComponent("ods/external-links.ods")

    @Test func xlsxNamesTheFileAndItsSheets() throws {
        let wb = try Workbook(contentsOf: Self.xlsx)
        #expect(wb.externalLinks == [ExternalLink(index: 1, target: "Budget.xlsx", sheetNames: ["Data", "Totals"])], "\(wb.externalLinks)")
        #expect(wb.sheets[0]["A1"]?.formula?.text == "=[1]Data!B2", "the formula keeps the number the link list explains")
        #expect(wb.sheets[0]["A1"]?.cachedValue == .integer(120), "the cached value is what the cell holds; nothing is resolved")
        #expect(wb.preservationSummary.parts[.externalLink] == 1)
    }

    @Test func aSameFormatWriteCarriesTheLinkUnchanged() throws {
        let source = try Data(contentsOf: Self.xlsx)
        let result = try Workbook(contentsOf: Self.xlsx).write(as: .xlsx)
        for part in ["xl/externalLinks/externalLink1.xml", "xl/externalLinks/_rels/externalLink1.xml.rels"] {
            #expect(try Package.part(part, of: result.data) == Package.part(part, of: source), Comment(rawValue: part))
        }
        #expect(try Package.part("xl/workbook.xml", of: result.data).contains("<externalReferences><externalReference r:id=\"rId2\"/></externalReferences>"))
        let back = try Workbook.read(result.data, format: .xlsx).workbook
        #expect(back.externalLinks == [ExternalLink(index: 1, target: "Budget.xlsx", sheetNames: ["Data", "Totals"])])
        #expect(back.sheets[0]["A2"]?.formula?.text == "=SUM([1]Totals!A1:A9)")
    }

    @Test func odsLinksAreTheDocumentsTheFormulasName() throws {
        let wb = try Workbook(contentsOf: Self.ods)
        #expect(wb.externalLinks == [ExternalLink(index: 1, target: "file:///home/user/Budget.ods", sheetNames: ["Data", "Totals"]),
                                     ExternalLink(index: 2, target: "file:///home/user/Rates.ods", sheetNames: ["FX 2026"])], "\(wb.externalLinks)")
        #expect(Workbook().externalLinks.isEmpty)
    }
}
