// # Turn a Numbers document into an Excel file you can share
//
// Writing to bytes first lets you look at the warnings — and at the suggestion the writer makes when the losses
// are serious enough that another format would carry more — before anything touches the disk.
import Foundation
import SwiftSheets

func numbersToExcel(in directory: URL) throws {
    let source = directory.appending(path: "budget.numbers")
    try makeSampleWorkbook(at: source)                    // stand-in for a document Numbers.app made

    let workbook = try Workbook(contentsOf: source)
    let result = try workbook.write(as: .xlsx)
    for warning in result.warnings { print(warning) }
    if let suggestion = result.suggestion {
        print("the writer suggests \(suggestion.format): \(suggestion.message)")
    }
    let target = directory.appending(path: "budget.xlsx")
    try result.data.write(to: target, options: .atomic)
    print("wrote", target.lastPathComponent, "(\(result.data.count) bytes)")
}
