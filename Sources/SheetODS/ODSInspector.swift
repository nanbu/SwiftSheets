import Foundation
import SheetCore

/// Answers `Workbook.inspect` for an OpenDocument package. ODS keeps every sheet in one part and says nothing
/// about a sheet's size up front, so the content is walked once as bytes: tables, their rows and the cells that
/// carry a value, with the run-length counts multiplied rather than expanded. A pass over the markup, no model.
package enum ODSInspector {
    package static func inspect(_ zip: ZipArchive, options: InspectOptions) throws -> WorkbookSummary {
        if let unopenable = UnopenableInput.probe(in: ZipInspection(archive: zip)) {
            guard unopenable == .encryptedODF, let password = options.password else { throw unopenable.error }
            let manifest = ManifestParser()
            try manifest.run(try zip.read("META-INF/manifest.xml"), part: "META-INF/manifest.xml")
            var plainOptions = options
            plainOptions.password = nil
            return try inspect(try ZipArchive(data: try ODSEncryption.decrypt(zip, entries: manifest.encryptedEntries, password: password), limits: options.limits), options: plainOptions)
        }
        guard zip.contains("content.xml") else { throw SheetError.malformedPart(path: "content.xml", detail: "content.xml missing from the package") }
        var sheets: [SheetSummary] = []
        var current: SheetSummary?
        var depth = 0                      // <table:table> nesting: a table inside a cell is not a sheet
        var rowRepeat = 1, rowCells = 0, rows = 0, cells = 0
        let stream = try zip.stream("content.xml")
        try TagScanner.scan({ try stream.next() }, names: ["table", "table-row", "table-cell", "covered-table-cell"]) { tag in
            switch tag.localName {
            case "table":
                if tag.isEnd {
                    depth -= 1
                    if depth == 0, var s = current {
                        s.rowCount = rows; s.declaredCellCount = cells
                        sheets.append(s); current = nil
                    }
                } else {
                    depth += 1
                    if depth == 1 {
                        current = SheetSummary(name: tag.attribute("table:name") ?? "Sheet\(sheets.count + 1)")
                        rows = 0; cells = 0
                    }
                }
            case "table-row" where depth == 1:
                if tag.isEnd {
                    if rowCells > 0 { rows += rowRepeat; cells += rowCells * rowRepeat }
                    rowCells = 0
                } else {
                    rowRepeat = Swift.max(1, Int(tag.attribute("table:number-rows-repeated") ?? "") ?? 1)
                    rowCells = 0
                }
            case "table-cell", "covered-table-cell":
                guard depth == 1, !tag.isEnd else { break }
                if tag.hasAttribute("office:value-type") || tag.hasAttribute("table:formula") {
                    rowCells += Swift.max(1, Int(tag.attribute("table:number-columns-repeated") ?? "") ?? 1)
                }
            default: break
            }
            return true
        }
        var producer = SourceInfo(format: .ods)
        if zip.contains("meta.xml") {
            let meta = MetaParser()
            try? meta.run(try zip.read("meta.xml"), part: "meta.xml")
            producer.application = meta.generator
        }
        let expanded = zip.entries.values.reduce(0) { $0 + $1.uncompressedSize }
        return WorkbookSummary(format: .ods, sheets: sheets, producer: producer, expandedBytes: expanded, partCount: zip.entries.count)
    }
}
