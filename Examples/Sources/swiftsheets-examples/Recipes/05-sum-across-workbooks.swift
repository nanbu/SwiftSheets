// # Add up the numbers in many workbooks without loading any of them whole
//
// `StreamingReader` walks a file of any format row by row — XLSX, ODS, Numbers or delimited text through the same
// call — holding a bounded amount of memory whatever the file's size. Values and formatting only: no merges, no
// notes, no preservation (see the README's Limits table).
import Foundation
import SwiftSheets

func sumAcrossWorkbooks(in directory: URL) throws {
    let files = try ["north.xlsx", "south.ods", "east.csv"].map { name -> URL in
        let url = directory.appending(path: name); try makeSampleWorkbook(at: url); return url
    }
    var total = Decimal(0)
    var rows = 0
    for file in files {
        let reader = try StreamingReader(contentsOf: file)
        for sheet in reader.sheetNames {
            try reader.forEachRow(inSheet: sheet) { row in
                rows += 1
                for cell in row.cells { if let n = cell.value?.numberValue { total += n } }
            }
        }
    }
    print("\(rows) rows over \(files.count) files, sum of every number: \(total)")
}
