// # What can go wrong, and how it is reported
//
// Failure is a thrown `SheetError`; degradation is a `ConversionWarning` on the result. An encrypted file is
// refused by name by the plain products — opening it is the `SheetDecrypt` product's job, so the core carries no
// cipher.
import Foundation
import SwiftSheets

func errorsAndWarnings(in directory: URL) throws {
    let notASpreadsheet = directory.appending(path: "photo.png")   // plain text would open as CSV; a picture cannot
    try onePixelPNG.write(to: notASpreadsheet)
    do {
        _ = try Workbook(contentsOf: notASpreadsheet)
    } catch let error as SheetError {
        switch error {
        case .unrecognizedFormat:              print("not a spreadsheet:", error)
        case .unopenable(let why):             print("recognised but refused (\(why)):", error)
        case .corruptedContainer(let detail):  print("damaged package:", detail)
        case .malformedPart(let path, let d):  print("damaged part \(path):", d)
        case .noCodec(let format):             print("link \(format.productName) to read \(format)")
        default:                               print("other:", error)
        }
    }

    // A workbook whose features the target format cannot carry: the write succeeds and says what went.
    var workbook = Workbook()
    workbook.editSheet(at: 0) { sheet in
        sheet["A1"] = "kept"
        sheet.tabColor = Color(hex: "FF0000")
        sheet.addStructuredTable(named: "T", over: "A1:A1")
    }
    let result = try workbook.write(as: .numbers)
    for warning in result.warnings {
        print("\(warning.kind) \(warning.subject)\(warning.sheet.map { " on \($0)" } ?? ""): \(warning.message)")
    }
}
