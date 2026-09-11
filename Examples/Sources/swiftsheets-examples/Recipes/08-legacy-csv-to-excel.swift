// # Import a Shift_JIS CSV and turn it into a formatted Excel file
//
// A CSV has no types: `inferTypes` recognises numbers, booleans and the date formats you name. The encoding is
// declared, so nothing is guessed; a byte the encoding cannot read is an error, not a garbled character.
import Foundation
import SwiftSheets

func legacyCSVToExcel(in directory: URL) throws {
    let csv = directory.appending(path: "orders.csv")
    let text = "Date,Customer,Amount\n2026/04/03,山田製作所,12500\n2026/04/11,中村商事,4800\n"
    try text.data(using: .shiftJIS)!.write(to: csv)

    var options = ReadOptions()
    options.csv = CSVReadOptions(encoding: .shiftJIS, inferTypes: true, dateFormats: ["yyyy/MM/dd"])
    var workbook = try Workbook(contentsOf: csv, options: options)
    workbook.editSheet(at: 0) { sheet in
        sheet.setStyle("A1:C1") { $0.font.bold = true }
        sheet.setStyle("A2:A3") { $0.numberFormat = NumberFormat.isoDate }
        sheet.setStyle("C2:C3") { $0.numberFormat = "#,##0" }
        sheet.autofitColumns()
    }
    let result = try workbook.write(to: directory.appending(path: "orders.xlsx"))
    print("orders.xlsx:", result.warnings.isEmpty ? "no warnings" : "\(result.warnings)")
}
