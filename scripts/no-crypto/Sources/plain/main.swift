import Foundation
import SwiftSheets

// The plain products only: read, inspect, walk and write, with no password anywhere. Given a file, opens it and
// prints what happened — a protected file is expected to be refused by name.
let url = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "")
do {
    let wb = try Workbook(contentsOf: url)
    print("read \(wb.sheets.count) sheet(s)")
    print("inspect \(try Workbook.inspect(contentsOf: url).sheets.count) sheet(s)")
    print("stream \(try StreamingReader(contentsOf: url).sheetNames)")
} catch {
    print("refused: \(error)")
}
var out = Workbook()
out.sheets[0]["A1"] = "x"
for format in [SheetFormat.xlsx, .ods, .numbers, .csv] { print("\(format) \(try out.data(as: format).count) bytes") }
