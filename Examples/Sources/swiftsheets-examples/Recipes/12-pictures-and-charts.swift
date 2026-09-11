// # Put a picture on a sheet and draw a chart from its cells
//
// A `SheetImage` reads its format and pixel size from the bytes (PNG, JPEG, GIF). A `Chart` is a kind, a title and
// series that point at ranges; unqualified ranges gain the sheet name. Both are read back from files that carry
// them, and re-packed byte for byte until one of them changes.
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
