import Foundation
import SheetEncrypt

// Everything: the positive control. Its symbol table is expected to hold the encrypting side, so that the script's
// patterns are proven to find what they look for before they are trusted to find nothing.
let url = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "")
let password = CommandLine.arguments.dropFirst(2).first ?? ""
do {
    let wb = try Workbook(contentsOf: url, password: password)
    print("read \(wb.sheets.count) sheet(s)")
    print("stream \(try StreamingReader(contentsOf: url, password: password).sheetNames)")
    print("decrypt \(try decrypt(contentsOf: url, password: password).count) bytes")
} catch {
    print("refused: \(error)")
}
var out = Workbook()
out.sheets[0]["A1"] = "x"
for format in [SheetFormat.xlsx, .ods] {
    let protected = try out.data(as: format, password: "p")
    print("\(format) protected \(protected.count) bytes, reopened \(try Workbook(data: protected, password: "p").sheets.count) sheet(s)")
    print("\(format) encrypt \(try encrypt(try out.data(as: format), as: format, password: "p").count) bytes")
}
