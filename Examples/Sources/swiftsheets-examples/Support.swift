import Foundation
import SwiftSheets

// Helpers the recipes share so that each one runs on its own: a small sample workbook to open, and a one-pixel PNG.
// None of this is part of the cookbook page (scripts/build-cookbook.py reads only Recipes/).

/// A workbook with a "Summary" sheet and a "Data" sheet, saved at `url` in the format its extension names.
@discardableResult
func makeSampleWorkbook(at url: URL) throws -> WriteResult {
    var wb = Workbook()
    wb.sheets[0].name = "Summary"
    wb.sheets[0]["A1"] = "Metric"; wb.sheets[0]["B1"] = "Value"
    wb.sheets[0]["A3"] = "Budget"; wb.sheets[0]["B3"] = 1_500_000
    wb.sheets[0]["A4"] = "Actual"; wb.sheets[0]["B4"] = 1_200_000
    wb.sheets[0]["A5"] = "Ratio";  wb.sheets[0]["B5"] = .formula("=B4/B3")
    let data = wb.addSheet(named: "Data")
    wb.sheets[data].append(["Region", "Quarter", "Units", "Revenue"])
    let regions = ["North", "South", "East", "West"]
    for (i, region) in regions.enumerated() {
        for quarter in 1...4 {
            wb.sheets[data].append([.text(region), .text("Q\(quarter)"), .integer(100 + 37 * i + 11 * quarter),
                                    .number(Decimal(1_250 + 310 * i + 95 * quarter))])
        }
    }
    return try wb.write(to: url)
}

/// A 1×1 transparent PNG — enough for `SheetImage(data:)` to read the format and the pixel size.
let onePixelPNG = Data(base64Encoded:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
