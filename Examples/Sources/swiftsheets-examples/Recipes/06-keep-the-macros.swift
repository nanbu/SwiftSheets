// # Replace the data in a macro-enabled workbook and keep its VBA
//
// VBA is preserved as opaque bytes — never run, never parsed — and written back when the file stays `.xlsm`.
// Writing the same workbook as `.xlsx` drops the project, and says so.
import Foundation
import SwiftSheets

func keepTheMacros(in directory: URL) throws {
    // the repository's fixture with a real VBA project; any .xlsm of your own works the same way
    let fixture = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../../Tests/SwiftSheetsTests/Fixtures/preservation/with-vba.xlsm").standardizedFileURL
    var workbook = try Workbook(contentsOf: fixture)
    print("has a VBA project:", workbook.preservationSummary.hasVBAProject)

    workbook.editSheet(at: 0) { sheet in
        sheet["A1"] = "Refreshed"
        sheet["B1"] = CellValue(CivilDate(year: 2026, month: 9, day: 11)!)
    }
    let kept = try workbook.write(to: directory.appending(path: "with-macros.xlsm"))
    print("as .xlsm:", kept.warnings.isEmpty ? "VBA kept, no warnings" : "\(kept.warnings)")

    let dropped = try workbook.write(to: directory.appending(path: "without-macros.xlsx"))
    print("as .xlsx:", dropped.warnings.map(\.message))
}
