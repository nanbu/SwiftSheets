import Foundation
import SwiftSheets

// One measurement per process: peak memory is the process's lifetime maximum, so two measurements in one
// process would share it. `scripts/bench.sh` runs each line of the table this way and gathers the JSON lines.
//
//   swiftsheets-bench <operation> <rows> <path>
//
// The workbook is 10 columns × <rows> rows: a label, five integers, three decimals, a Japanese category — the
// same synthetic material spec Appendix B.39 was measured with. It is synthetic on purpose (the numbers in
// docs/performance.json say so): representative of a data export, not of a formatted report.

func peakMB() -> Double {
    var u = rusage(); getrusage(RUSAGE_SELF, &u)
    #if os(Linux)
    return Double(u.ru_maxrss) / 1024.0        // kilobytes on Linux
    #else
    return Double(u.ru_maxrss) / 1_048_576.0   // bytes on Darwin
    #endif
}
func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
func report(_ op: String, _ rows: Int, _ sec: Double, _ note: String = "") {
    print(#"{"op":"\#(op)","rows":\#(rows),"sec":\#(String(format: "%.3f", sec)),"peakMB":\#(String(format: "%.1f", peakMB()))\#(note.isEmpty ? "" : #","note":"\#(note)""#)}"#)
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
    [.text("R\(i)"),
     .integer(i), .integer(i * 7), .integer(i % 97), .integer(i &* 13 % 1000),
     .number(Decimal(i) + Decimal(string: "0.5")!), .number(Decimal(i * 3) + Decimal(string: "0.25")!),
     .number(Decimal(i % 31) + Decimal(string: "0.125")!),
     .text(i % 2 == 0 ? "分類A" : "分類B"),
     .integer(i * 2)]
}
func workbook() -> Workbook {
    var wb = Workbook()
    for i in 0..<rows { wb.sheets[0].append(row(i)) }
    return wb
}
func sum(_ wb: Workbook) -> Decimal {
    var total = Decimal(0)
    for r in wb.sheets[0].values() { for v in r { if let n = v?.numberValue { total += n } } }
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
    case "streamRead", "streamReadODS", "streamReadNumbers":
        // the one streaming reader for every format (spec Appendix B.40): the file's format decides the walker
        var total = Decimal(0)
        let t = try clock.measure {
            let reader = try StreamingReader(contentsOf: url)
            try reader.forEachRow(inSheet: reader.sheetNames[0]) { r in for c in r.cells { if let n = c.value?.numberValue { total += n } } }
        }
        report(op, rows, seconds(t), "sum=\(total)")
    case "streamWrite":
        let t = try clock.measure {
            let w = try StreamingWriter(url: url, sheetName: "Sheet1")
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
