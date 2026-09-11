// # Build a formatted report from scratch
//
// A new workbook has one empty sheet. Append rows, style ranges by A1 address, set number formats, freeze the
// header, add an auto-filter, and let the columns size themselves to their content.
import Foundation
import SwiftSheets

func reportFromScratch(in directory: URL) throws {
    var workbook = Workbook()
    workbook.metadata.title = "Quarterly sales"
    workbook.sheets[0].name = "Sales"
    workbook.editSheet(at: 0) { sheet in
        sheet.append(["Region", "Quarter", "Units", "Revenue"])
        for (i, region) in ["North", "South", "East"].enumerated() {
            for quarter in 1...4 {
                sheet.append([.text(region), .text("Q\(quarter)"), .integer(120 + 40 * i + 9 * quarter),
                              .number(Decimal(string: "1499.50")! + Decimal(300 * i + 80 * quarter))])
            }
        }
        sheet["C14"] = .formula("=SUM(C2:C13)")
        sheet["D14"] = .formula("=SUM(D2:D13)")
        sheet.setStyle("A1:D1") {
            $0.font.bold = true
            $0.fill = .solid(Color(hex: "DDEBF7"))
            $0.alignment.horizontal = .center
        }
        sheet.setStyle("D2:D14") { $0.numberFormat = "#,##0.00" }
        sheet.setStyle("A14:D14") { $0.font.bold = true }
        sheet.freezePanes = CellRef("A2")                 // rows above A2 stay put
        sheet.autoFilter = CellRange("A1:D13")
        sheet.autofitColumns()
    }
    let result = try workbook.write(to: directory.appending(path: "sales.xlsx"))
    print("sales.xlsx:", result.warnings.isEmpty ? "no warnings" : "\(result.warnings)")
}
