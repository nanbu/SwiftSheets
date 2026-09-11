# SwiftSheets cookbook

Thirteen things people do with a spreadsheet library, each as a complete function that compiles and runs. The code
on this page **is** the code under [`Examples/`](../Examples/Sources/swiftsheets-examples/Recipes): the page is
generated from it (`scripts/build-cookbook.py`), CI builds the package on every push and runs every recipe on
macOS, so an example here cannot silently stop working.

Run one yourself, from a checkout:

```bash
swift run --package-path Examples swiftsheets-examples all /tmp/swiftsheets-cookbook
```

Every recipe takes a directory, writes what it makes there, and prints what it did. The helpers they share
(`makeSampleWorkbook`, a one-pixel PNG) are in `Support.swift` and exist only so each recipe runs on its own.
New to the library? Start with [Getting started](getting-started.md).

## Contents

- [Open an Excel file, change a few cells, save it](#open-an-excel-file-change-a-few-cells-save-it)
- [Build a formatted report from scratch](#build-a-formatted-report-from-scratch)
- [Convert every Excel file in a folder to ODS, with a log of what each conversion lost](#convert-every-excel-file-in-a-folder-to-ods-with-a-log-of-what-each-conversion-lost)
- [Turn a Numbers document into an Excel file you can share](#turn-a-numbers-document-into-an-excel-file-you-can-share)
- [Add up the numbers in many workbooks without loading any of them whole](#add-up-the-numbers-in-many-workbooks-without-loading-any-of-them-whole)
- [Replace the data in a macro-enabled workbook and keep its VBA](#replace-the-data-in-a-macro-enabled-workbook-and-keep-its-vba)
- [Write a file with more rows than memory](#write-a-file-with-more-rows-than-memory)
- [Import a Shift_JIS CSV and turn it into a formatted Excel file](#import-a-shift-jis-csv-and-turn-it-into-a-formatted-excel-file)
- [Ask a file what it holds before reading it — for input you do not trust](#ask-a-file-what-it-holds-before-reading-it-for-input-you-do-not-trust)
- [Link only the formats you need](#link-only-the-formats-you-need)
- [Data validation, conditional formatting, a structured table, notes and links](#data-validation-conditional-formatting-a-structured-table-notes-and-links)
- [Put a picture on a sheet and draw a chart from its cells](#put-a-picture-on-a-sheet-and-draw-a-chart-from-its-cells)
- [What can go wrong, and how it is reported](#what-can-go-wrong-and-how-it-is-reported)

## Open an Excel file, change a few cells, save it

The everyday case. The format is detected from the bytes, not the extension. Sheets are value types, so `editSheet` edits one in place and there is nothing to put back; a closure that throws leaves the workbook untouched. Everything you did not touch — charts, pivot caches, macros, styles — is written back exactly as it came in, and the write answers with the list of what the format could not carry.

_[`01-open-edit-save.swift`](../Examples/Sources/swiftsheets-examples/Recipes/01-open-edit-save.swift)_

```swift
import Foundation
import SwiftSheets

func openEditSave(in directory: URL) throws {
    let url = directory.appending(path: "monthly-report.xlsx")
    try makeSampleWorkbook(at: url)                       // a stand-in for the file you already have

    var workbook = try Workbook(contentsOf: url)
    try workbook.editSheet(named: "Summary") { sheet in
        sheet["B4"] = 1_380_000                           // Int, Double, Decimal, String, Bool literals all work
        sheet["B5"] = .formula("=B4/B3")                  // parsed into a tree; follows row inserts and renames
        sheet.setStyle("A1:B1") { $0.font.bold = true }
    }
    let result = try workbook.write(to: url)              // the file is saved when this returns
    for warning in result.warnings { print("write:", warning) }
    for warning in workbook.readWarnings { print("read:", warning) }
    print("saved", url.lastPathComponent, "with", result.warnings.count, "write warning(s)")
}
```

## Build a formatted report from scratch

A new workbook has one empty sheet. Append rows, style ranges by A1 address, set number formats, freeze the header, add an auto-filter, and let the columns size themselves to their content.

_[`02-report-from-scratch.swift`](../Examples/Sources/swiftsheets-examples/Recipes/02-report-from-scratch.swift)_

```swift
import Foundation
import SwiftSheets

func reportFromScratch(in directory: URL) throws {
    var workbook = Workbook()
    workbook.metadata.title = "Quarterly sales"
    workbook.sheets[0].name = "Sales"
    workbook.editSheet(at: 0) { sheet in
        sheet.append(["Region", "Quarter", "Units", "Revenue"])
        for (i, region) in ["North", "South", "East"].enumerated() {
            for quarter in 1...4 {
                sheet.append([.text(region), .text("Q\(quarter)"), .integer(120 + 40 * i + 9 * quarter),
                              .number(Decimal(string: "1499.50")! + Decimal(300 * i + 80 * quarter))])
            }
        }
        sheet["C14"] = .formula("=SUM(C2:C13)")
        sheet["D14"] = .formula("=SUM(D2:D13)")
        sheet.setStyle("A1:D1") {
            $0.font.bold = true
            $0.fill = .solid(Color(hex: "DDEBF7"))
            $0.alignment.horizontal = .center
        }
        sheet.setStyle("D2:D14") { $0.numberFormat = "#,##0.00" }
        sheet.setStyle("A14:D14") { $0.font.bold = true }
        sheet.freezePanes = CellRef("A2")                 // rows above A2 stay put
        sheet.autoFilter = CellRange("A1:D13")
        sheet.autofitColumns()
    }
    let result = try workbook.write(to: directory.appending(path: "sales.xlsx"))
    print("sales.xlsx:", result.warnings.isEmpty ? "no warnings" : "\(result.warnings)")
}
```

## Convert every Excel file in a folder to ODS, with a log of what each conversion lost

`Workbook.convert` reads, writes and answers with the warnings of both halves. What ODS cannot express — a feature Excel alone has — is reported per file, never dropped in silence.

_[`03-convert-a-folder.swift`](../Examples/Sources/swiftsheets-examples/Recipes/03-convert-a-folder.swift)_

```swift
import Foundation
import SwiftSheets

func convertAFolder(in directory: URL) throws {
    let input = directory.appending(path: "incoming")
    let output = directory.appending(path: "converted")
    try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for name in ["january", "february"] { try makeSampleWorkbook(at: input.appending(path: "\(name).xlsx")) }

    var log: [String] = []
    let files = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "xlsx" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    for file in files {
        let target = output.appending(path: file.deletingPathExtension().lastPathComponent + ".ods")
        let result = try Workbook.convert(file, to: target, as: .ods)   // the format is always named
        log.append("\(file.lastPathComponent) → \(target.lastPathComponent): \(result.warnings.count) warning(s)")
        for warning in result.warnings { log.append("  \(warning)") }
    }
    try log.joined(separator: "\n").write(to: output.appending(path: "conversion.log"), atomically: true, encoding: .utf8)
    print(log.joined(separator: "\n"))
}
```

## Turn a Numbers document into an Excel file you can share

Writing to bytes first lets you look at the warnings — and at the suggestion the writer makes when the losses are serious enough that another format would carry more — before anything touches the disk.

_[`04-numbers-to-excel.swift`](../Examples/Sources/swiftsheets-examples/Recipes/04-numbers-to-excel.swift)_

```swift
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
```

## Add up the numbers in many workbooks without loading any of them whole

`StreamingReader` walks a file of any format row by row — XLSX, ODS, Numbers or delimited text through the same call — holding a bounded amount of memory whatever the file's size. Values and formatting only: no merges, no notes, no preservation (see the README's Limits table).

_[`05-sum-across-workbooks.swift`](../Examples/Sources/swiftsheets-examples/Recipes/05-sum-across-workbooks.swift)_

```swift
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
```

## Replace the data in a macro-enabled workbook and keep its VBA

VBA is preserved as opaque bytes — never run, never parsed — and written back when the file stays `.xlsm`. Writing the same workbook as `.xlsx` drops the project, and says so.

_[`06-keep-the-macros.swift`](../Examples/Sources/swiftsheets-examples/Recipes/06-keep-the-macros.swift)_

```swift
import Foundation
import SwiftSheets

func keepTheMacros(in directory: URL) throws {
    // the repository's fixture with a real VBA project; any .xlsm of your own works the same way
    let fixture = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../../Tests/SwiftSheetsTests/Fixtures/preservation/with-vba.xlsm").standardizedFileURL
    var workbook = try Workbook(contentsOf: fixture)
    print("has a VBA project:", workbook.preservationSummary.hasVBAProject)

    workbook.editSheet(at: 0) { sheet in
        sheet["A1"] = "Refreshed"
        sheet["B1"] = CellValue(CivilDate(year: 2026, month: 9, day: 11)!)
    }
    let kept = try workbook.write(to: directory.appending(path: "with-macros.xlsm"))
    print("as .xlsm:", kept.warnings.isEmpty ? "VBA kept, no warnings" : "\(kept.warnings)")

    let dropped = try workbook.write(to: directory.appending(path: "without-macros.xlsx"))
    print("as .xlsx:", dropped.warnings.map(\.message))
}
```

## Write a file with more rows than memory

The rows go into a temporary file beside the destination, which is replaced only once the file is complete — in every format. A row that fails or a closure that throws leaves whatever was at that path untouched.

_[`07-write-row-by-row.swift`](../Examples/Sources/swiftsheets-examples/Recipes/07-write-row-by-row.swift)_

```swift
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
```

## Import a Shift_JIS CSV and turn it into a formatted Excel file

A CSV has no types: `inferTypes` recognises numbers, booleans and the date formats you name. The encoding is declared, so nothing is guessed; a byte the encoding cannot read is an error, not a garbled character.

_[`08-legacy-csv-to-excel.swift`](../Examples/Sources/swiftsheets-examples/Recipes/08-legacy-csv-to-excel.swift)_

```swift
import Foundation
import SwiftSheets

func legacyCSVToExcel(in directory: URL) throws {
    let csv = directory.appending(path: "orders.csv")
    let text = "Date,Customer,Amount\n2026/04/03,山田製作所,12500\n2026/04/11,中村商事,4800\n"
    try text.data(using: .shiftJIS)!.write(to: csv)

    var options = ReadOptions()
    options.csv = CSVReadOptions(encoding: .shiftJIS, inferTypes: true, dateFormats: ["yyyy/MM/dd"])
    var workbook = try Workbook(contentsOf: csv, options: options)
    workbook.editSheet(at: 0) { sheet in
        sheet.setStyle("A1:C1") { $0.font.bold = true }
        sheet.setStyle("A2:A3") { $0.numberFormat = NumberFormat.isoDate }
        sheet.setStyle("C2:C3") { $0.numberFormat = "#,##0" }
        sheet.autofitColumns()
    }
    let result = try workbook.write(to: directory.appending(path: "orders.xlsx"))
    print("orders.xlsx:", result.warnings.isEmpty ? "no warnings" : "\(result.warnings)")
}
```

## Ask a file what it holds before reading it — for input you do not trust

`inspect` reads the package directory and each sheet's declared extent without expanding a cell, so you can set a cell budget before the real read. `probe` says whether a file is a spreadsheet at all, or something the library recognises but will not open (an encrypted file, a legacy `.xls`).

_[`09-inspect-before-reading.swift`](../Examples/Sources/swiftsheets-examples/Recipes/09-inspect-before-reading.swift)_

```swift
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
```

## Link only the formats you need

An app that links `SheetXLSX` and `SheetODS` — no CSV, no Numbers, no umbrella — has the same entry points through a `CodecSet` of the codecs it links. A format the set lacks is refused by name, with the product to link; a format whose product is not linked is a compile error at the line that names it.

_[`10-only-some-formats.swift`](../Examples/Sources/swiftsheets-examples/Recipes/10-only-some-formats.swift)_

```swift
import Foundation
import SheetCore
import SheetXLSX
import SheetODS

func onlySomeFormats(in directory: URL) throws {
    let codecs = CodecSet([.xlsx, .xlsm, .ods])
    let url = directory.appending(path: "subset.ods")
    var workbook = Workbook()
    workbook.sheets[0]["A1"] = "hello"
    _ = try codecs.write(workbook, to: url)

    let summary = try codecs.inspect(contentsOf: url)
    let back = try codecs.read(contentsOf: url).workbook
    print("read back \(back.sheets[0]["A1"]!) from a \(summary.format) file")

    do {
        _ = try codecs.read(contentsOf: directory.appending(path: "orders.csv"))
    } catch SheetError.noCodec(let format) {
        print("refused: no codec for \(format) — link \(format.productName)")
    } catch {
        print("orders.csv is not there yet; run the legacy-csv-to-excel recipe first (\(error))")
    }
}
```

## Data validation, conditional formatting, a structured table, notes and links

The sheet-level features Excel users reach for first. Each is a value on the sheet; the writer of every format says what it could not carry.

_[`11-validation-and-formatting.swift`](../Examples/Sources/swiftsheets-examples/Recipes/11-validation-and-formatting.swift)_

```swift
import Foundation
import SwiftSheets

func validationAndFormatting(in directory: URL) throws {
    var workbook = Workbook()
    workbook.editSheet(at: 0) { sheet in
        sheet.name = "Tasks"
        sheet.append(["Task", "Hours", "Status", "Link"])
        sheet.append(["Write the guide", 12, "Doing", nil])
        sheet.append(["Review the API", 140, "Todo", nil])
        sheet.dataValidations = [
            .list(choices: ["Todo", "Doing", "Done"], over: MultiCellRange("C2:C50")!)!
        ]
        sheet.addConditionalFormatting(.cellIs(.greaterThan, "100", paint: .highlight(fill: Color(hex: "FFC7CE"))),
                                       over: "B2:B50")
        sheet.addStructuredTable(named: "Tasks", over: "A1:D3")
        sheet[cell: "A1"].note = CellNote("One row per task.", author: "Reviewer")
        sheet[cell: "D2"].hyperlink = Hyperlink(target: "https://github.com/nanbu/SwiftSheets", display: "repository")
        sheet[cell: "D2"].value = "repository"
    }
    let result = try workbook.write(to: directory.appending(path: "tasks.xlsx"))
    print("tasks.xlsx:", result.warnings.isEmpty ? "no warnings" : "\(result.warnings)")
}
```

## Put a picture on a sheet and draw a chart from its cells

A `SheetImage` reads its format and pixel size from the bytes (PNG, JPEG, GIF). A `Chart` is a kind, a title and series that point at ranges; unqualified ranges gain the sheet name. Both are read back from files that carry them, and re-packed byte for byte until one of them changes.

_[`12-pictures-and-charts.swift`](../Examples/Sources/swiftsheets-examples/Recipes/12-pictures-and-charts.swift)_

```swift
import Foundation
import SwiftSheets

func picturesAndCharts(in directory: URL) throws {
    var workbook = Workbook()
    workbook.editSheet(at: 0) { sheet in
        sheet.name = "Units"
        sheet.append(["Region", "Units"])
        for (region, units) in [("North", 120), ("South", 95), ("East", 143), ("West", 88)] {
            sheet.append([.text(region), .integer(units)])
        }
        var chart = Chart(.column, title: "Units by region")
        chart.addSeries(values: "B2:B5", categories: "A2:A5", name: "Units")
        sheet.addChart(chart, over: "D2:K16")

        let image = try! SheetImage(data: onePixelPNG)
        sheet.addImage(image, at: "A8", sizing: .scaled(width: 64, height: 64))
    }
    let result = try workbook.write(to: directory.appending(path: "units.xlsx"))
    print("units.xlsx:", result.warnings.isEmpty ? "no warnings" : "\(result.warnings)")

    let back = try Workbook(contentsOf: directory.appending(path: "units.xlsx"))
    print("read back \(back.sheets[0].charts.count) chart(s) and \(back.sheets[0].images.count) image(s)")
}
```

## What can go wrong, and how it is reported

Failure is a thrown `SheetError`; degradation is a `ConversionWarning` on the result. An encrypted file is refused by name by the plain products — opening it is the `SheetDecrypt` product's job, so the core carries no cipher.

_[`13-errors-and-warnings.swift`](../Examples/Sources/swiftsheets-examples/Recipes/13-errors-and-warnings.swift)_

```swift
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
```
