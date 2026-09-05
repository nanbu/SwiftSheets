import Foundation
import SwiftSheets

// One measurement per process: peak memory is the process's lifetime maximum, so two measurements in one
// process would share it. `scripts/bench.sh` runs each line of the table this way and gathers the JSON lines.
//
//   swiftsheets-bench <operation> <rows> <path>
//
// The workbook is SWIFTSHEETS_BENCH_COLUMNS columns (100 by default — the standard of Appendix B.39.11: 100 columns ×
// 10,000 rows and × 100,000 rows, driven by scripts/bench.py) × <rows> rows. The material is a block of ten — a label,
// five integers, three decimals, a Japanese category — repeated across the width with the numbers offset per
// block; the text columns past the first block draw on a vocabulary of fifty, as an export's do, so the distinct
// strings grow with the rows, not with the width. It is synthetic on purpose (the numbers in docs/performance.json
// say so): representative of a data export, not of a formatted report.

func peakMB() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    #if os(Linux)
    return Double(u.ru_maxrss) / 1024.0        // kilobytes on Linux
    #else
    return Double(u.ru_maxrss) / 1_048_576.0   // bytes on Darwin
    #endif
}
func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
let columns = Int(ProcessInfo.processInfo.environment["SWIFTSHEETS_BENCH_COLUMNS"] ?? "") ?? 100
func report(_ op: String, _ rows: Int, _ sec: Double, _ note: String = "") {
    print(#"{"op":"\#(op)","rows":\#(rows),"columns":\#(columns),"sec":\#(String(format: "%.3f", sec)),"peakMB":\#(String(format: "%.1f", peakMB()))\#(note.isEmpty ? "" : #","note":"\#(note)""#)}"#)
}

let args = CommandLine.arguments
guard args.count >= 4, let rows = Int(args[2]) else {
    FileHandle.standardError.write(Data("usage: swiftsheets-bench <operation> <rows> <path>\n".utf8))
    exit(2)
}
let op = args[1]
let url = URL(filePath: args[3])
let clock = ContinuousClock()

func row(_ i: Int) -> [CellValue?] {
    var r: [CellValue?] = []
    r.reserveCapacity(columns)
    var block = 0
    while r.count < columns {
        let n = i + block
        let base: [CellValue?] = [
            .text(block == 0 ? "R\(i)" : "品目\(n % 50)"),
            .integer(n), .integer(n * 7), .integer(n % 97), .integer(n &* 13 % 1000),
            .number(Decimal(n) + Decimal(string: "0.5")!), .number(Decimal(n * 3) + Decimal(string: "0.25")!),
            .number(Decimal(n % 31) + Decimal(string: "0.125")!),
            .text(n % 2 == 0 ? "分類A" : "分類B"),
            .integer(n * 2)]
        r.append(contentsOf: base.prefix(columns - r.count))
        block += 1
    }
    return r
}
/// The multi-sheet book (spec Appendix B.41): the same million cells dealt over this many sheets, so that a read
/// side by side and a read one sheet at a time are measured on the same material.
let sheetsInMultiSheetBook = 8
func workbook(sheets: Int = 1) -> Workbook {
    var wb = Workbook()
    for s in 1..<sheets { wb.addSheet(named: "Sheet\(s + 1)") }
    for i in 0..<rows { wb.sheets[i % sheets].append(row(i)) }
    return wb
}
func sum(_ wb: Workbook) -> Decimal {
    var total = Decimal(0)
    for sheet in wb.sheets { for r in sheet.values() { for v in r { if let n = v?.numberValue { total += n } } } }
    return total
}

do {
    switch op {
    case "build":
        var wb: Workbook?
        let t = clock.measure { wb = workbook() }
        report(op, rows, seconds(t), "cells=\(wb!.sheets[0].table.cells.count)")
    case "write", "writeODS", "writeCSV", "writeNumbers":
        let wb = workbook()
        let format: SheetFormat = op == "writeODS" ? .ods : op == "writeCSV" ? .csv : op == "writeNumbers" ? .numbers : .xlsx
        let before = peakMB()
        let t = try clock.measure { try wb.write(to: url, as: format) }
        report(op, rows, seconds(t), "modelMB=\(String(format: "%.1f", before))")
    case "read", "readODS", "readCSV", "readNumbers":
        var total = Decimal(0)
        let t = try clock.measure { total = sum(try Workbook(contentsOf: url, options: ReadOptions(csv: CSVReadOptions(inferTypes: true)))) }
        report(op, rows, seconds(t), "sum=\(total)")
    case "writeSheets":
        let wb = workbook(sheets: sheetsInMultiSheetBook)
        let before = peakMB()
        let t = try clock.measure { try wb.write(to: url) }
        report(op, rows, seconds(t), "sheets=\(sheetsInMultiSheetBook) modelMB=\(String(format: "%.1f", before))")
    case "readSheets", "readSheetsSerial":
        // the sheets side by side (the default decides so for a book this size) against one at a time
        var total = Decimal(0)
        let options = ReadOptions(concurrency: op == "readSheetsSerial" ? 1 : nil)
        let t = try clock.measure { total = sum(try Workbook(contentsOf: url, options: options)) }
        report(op, rows, seconds(t), "sheets=\(sheetsInMultiSheetBook) sum=\(total)")
    case "streamRead", "streamReadODS", "streamReadNumbers":
        // the one streaming reader for every format (spec Appendix B.40): the file's format decides the walker
        var total = Decimal(0)
        let t = try clock.measure {
            let reader = try StreamingReader(contentsOf: url)
            try reader.forEachRow(inSheet: reader.sheetNames[0]) { r in for c in r.cells { if let n = c.value?.numberValue { total += n } } }
        }
        report(op, rows, seconds(t), "sum=\(total)")
    case "streamWrite", "streamWriteODS", "streamWriteNumbers":
        // the one streaming writer for every format (spec Appendix B.42): the path's extension decides the writer
        let t = try clock.measure {
            let w = try StreamingWriter(url: url, sheetName: "Sheet1")
            for i in 0..<rows { try w.append(row(i)) }
            try w.close()
        }
        report(op, rows, seconds(t))
    case "streamWriteCSV":
        let t = try clock.measure {
            let w = try CSVStreamingWriter(url: url)
            for i in 0..<rows { try w.append(row(i)) }
            try w.close()
        }
        report(op, rows, seconds(t))
    case "streamReadCSV":
        var total = Decimal(0)
        let t = try clock.measure {
            try CSVStreamingReader(contentsOf: url, options: CSVReadOptions(inferTypes: true)).forEachRow { r in for v in r { if let n = v?.numberValue { total += n } } }
        }
        report(op, rows, seconds(t), "sum=\(total)")
    case "edit":
        let t = try clock.measure {
            var wb = try Workbook(contentsOf: url)
            wb.sheets[0]["A1"] = "edited"
            try wb.write(to: url.appendingPathExtension("out.xlsx"))
        }
        report(op, rows, seconds(t))
    case "detect":
        var f: SheetFormat?
        let n = 200
        let t = try clock.measure { for _ in 0..<n { f = try SheetFormat.detect(contentsOf: url) } }
        report(op, rows, seconds(t) / Double(n), "format=\(f.map { $0.rawValue } ?? "nil")")
    case "inspect":
        var cells: Int?
        let t = try clock.measure { cells = try Workbook.inspect(contentsOf: url).declaredCellCount }
        report(op, rows, seconds(t), "declaredCells=\(cells ?? -1)")
    default:
        FileHandle.standardError.write(Data("unknown operation \(op)\n".utf8))
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("\(op) failed: \(error)\n".utf8))
    exit(1)
}
