// # Data validation, conditional formatting, a structured table, notes and links
//
// The sheet-level features Excel users reach for first. Each is a value on the sheet; the writer of every format
// says what it could not carry.
import Foundation
import SwiftSheets

func validationAndFormatting(in directory: URL) throws {
    var workbook = Workbook()
    workbook.editSheet(at: 0) { sheet in
        sheet.name = "Tasks"
        sheet.append(["Task", "Hours", "Status", "Link"])
        sheet.append(["Write the guide", 12, "Doing", nil])
        sheet.append(["Review the API", 140, "Todo", nil])
        sheet.dataValidations = [
            .list(choices: ["Todo", "Doing", "Done"], over: MultiCellRange("C2:C50")!)!
        ]
        sheet.addConditionalFormatting(.cellIs(.greaterThan, "100", paint: .highlight(fill: Color(hex: "FFC7CE"))),
                                       over: "B2:B50")
        sheet.addStructuredTable(named: "Tasks", over: "A1:D3")
        sheet[cell: "A1"].note = CellNote("One row per task.", author: "Reviewer")
        sheet[cell: "D2"].hyperlink = Hyperlink(target: "https://github.com/nanbu/SwiftSheets", display: "repository")
        sheet[cell: "D2"].value = "repository"
    }
    let result = try workbook.write(to: directory.appending(path: "tasks.xlsx"))
    print("tasks.xlsx:", result.warnings.isEmpty ? "no warnings" : "\(result.warnings)")
}
