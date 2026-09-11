// # Link only the formats you need
//
// An app that links `SheetXLSX` and `SheetODS` — no CSV, no Numbers, no umbrella — has the same entry points
// through a `CodecSet` of the codecs it links. A format the set lacks is refused by name, with the product to
// link; a format whose product is not linked is a compile error at the line that names it.
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
