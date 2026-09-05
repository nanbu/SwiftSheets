import Foundation
import SheetDecrypt

// The plain products plus SheetDecrypt: the same, and a protected file opened with its password (the second
// argument). Nothing here encrypts.
let url = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "")
let password = CommandLine.arguments.dropFirst(2).first ?? ""
do {
    let wb = try Workbook(contentsOf: url, password: password)
    print("read \(wb.sheets.count) sheet(s)")
    print("inspect \(try Workbook.inspect(contentsOf: url, password: password).sheets.count) sheet(s)")
    print("stream \(try StreamingReader(contentsOf: url, password: password).sheetNames)")
    print("decrypt \(try decrypt(contentsOf: url, password: password).count) bytes")
} catch {
    print("refused: \(error)")
}
var out = Workbook()
out.sheets[0]["A1"] = "x"
for format in [SheetFormat.xlsx, .ods, .numbers, .csv] { print("\(format) \(try out.data(as: format).count) bytes") }
