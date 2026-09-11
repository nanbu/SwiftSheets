// # Ask a file what it holds before reading it — for input you do not trust
//
// `inspect` reads the package directory and each sheet's declared extent without expanding a cell, so you can set
// a cell budget before the real read. `probe` says whether a file is a spreadsheet at all, or something the
// library recognises but will not open (an encrypted file, a legacy `.xls`).
import Foundation
import SwiftSheets

func inspectBeforeReading(in directory: URL) throws {
    let url = directory.appending(path: "upload.xlsx")
    try makeSampleWorkbook(at: url)

    print("probe:", try SheetFormat.probe(contentsOf: url))
    let summary = try Workbook.inspect(contentsOf: url)
    print("format \(summary.format), \(summary.partCount) parts, \(summary.expandedBytes) bytes expanded")
    for sheet in summary.sheets {
        print("  \(sheet.name): declares \(sheet.declaredCellCount.map(String.init) ?? "?") cells")
    }

    var options = ReadOptions()
    options.cellLimit = 200_000                             // reading stops here with a `degraded` warning
    options.limits.maxEntries = 10_000                      // package limits, raised or lowered per file
    let result = try Workbook.read(contentsOf: url, options: options)
    print("read \(result.workbook.sheetNames) with \(result.warnings.count) warning(s)")
}
