// # Open an Excel file, change a few cells, save it
//
// The everyday case. The format is detected from the bytes, not the extension. Sheets are value types, so
// `editSheet` edits one in place and there is nothing to put back; a closure that throws leaves the workbook
// untouched. Everything you did not touch — charts, pivot caches, macros, styles — is written back exactly as it
// came in, and the write answers with the list of what the format could not carry.
import Foundation
import SwiftSheets

func openEditSave(in directory: URL) throws {
    let url = directory.appending(path: "monthly-report.xlsx")
    try makeSampleWorkbook(at: url)                       // a stand-in for the file you already have

    var workbook = try Workbook(contentsOf: url)
    try workbook.editSheet(named: "Summary") { sheet in
        sheet["B4"] = 1_380_000                           // Int, Double, Decimal, String, Bool literals all work
        sheet["B5"] = .formula("=B4/B3")                  // parsed into a tree; follows row inserts and renames
        sheet.setStyle("A1:B1") { $0.font.bold = true }
    }
    let result = try workbook.write(to: url)              // the file is saved when this returns
    for warning in result.warnings { print("write:", warning) }
    for warning in workbook.readWarnings { print("read:", warning) }
    print("saved", url.lastPathComponent, "with", result.warnings.count, "write warning(s)")
}
