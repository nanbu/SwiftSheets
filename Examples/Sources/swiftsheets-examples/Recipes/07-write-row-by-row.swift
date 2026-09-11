// # Write a file with more rows than memory
//
// The rows go into a temporary file beside the destination, which is replaced only once the file is complete —
// in every format. A row that fails or a closure that throws leaves whatever was at that path untouched.
import Foundation
import SwiftSheets

func writeRowByRow(in directory: URL) throws {
    let url = directory.appending(path: "ledger.xlsx")
    let result = try CodecSet.all.withStreamingWriter(to: url, as: .xlsx, sheetName: "Ledger") { writer in
        try writer.append([.text("Id"), .text("Account"), .text("Amount")])
        for i in 1...50_000 {
            try writer.append([.integer(i), .text("ACC-\(i % 97)"), .number(Decimal(i) / 100)])
        }
    }
    print("ledger.xlsx saved;", result.warnings.count, "warning(s)")

    // Opening one by hand: append, then close() — which returns the same result and must be called.
    let writer = try StreamingWriter(to: directory.appending(path: "ledger.csv"), as: .csv)
    try writer.append([.text("a"), .text("b")])
    try writer.append([.integer(1), .integer(2)])
    _ = try writer.close()
}
