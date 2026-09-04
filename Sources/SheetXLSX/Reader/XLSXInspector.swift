import Foundation
import SheetCore

/// Answers `Workbook.inspect` for an OOXML package: the workbook part names the sheets, each sheet's own part
/// says its used range at the top (`<dimension>`), and the ZIP directory says what everything expands to. Nothing
/// past the first piece of a sheet part is read unless the caller asks for a count.
package enum XLSXInspector {
    package static func inspect(_ zip: ZipArchive, format: SheetFormat, options: InspectOptions) throws -> WorkbookSummary {
        let rootRels = (try? WorkbookReader.parseRels(zip, "_rels/.rels")) ?? []
        let workbookPath = rootRels.first { $0.type.hasSuffix(WorkbookReader.relOfficeDocument) }
            .map { WorkbookReader.resolvePart($0.target, relativeTo: "") } ?? "xl/workbook.xml"
        guard zip.contains(workbookPath) else { throw SheetError.malformedPart(path: workbookPath, detail: "workbook part missing") }
        let wbParser = WorkbookXMLParser()
        try wbParser.run(try zip.read(workbookPath), part: workbookPath)
        let base = (workbookPath as NSString).deletingLastPathComponent
        let rels = (try? WorkbookReader.parseRels(zip, WorkbookReader.relsPath(of: workbookPath))) ?? []

        var sheets: [SheetSummary] = []
        for info in wbParser.sheets {
            var summary = SheetSummary(name: info.name)
            guard let rel = rels.first(where: { $0.id == info.rId }) else { sheets.append(summary); continue }
            let part = WorkbookReader.resolvePart(rel.target, relativeTo: base)
            summary.partBytes = zip.entries[part]?.uncompressedSize
            guard rel.type.hasSuffix(WorkbookReader.relWorksheet), zip.contains(part) else {
                summary.isGrid = false
                sheets.append(summary)
                continue
            }
            // the declaration sits before <sheetData>: stop at whichever comes first
            let stream = try zip.stream(part)
            try TagScanner.scan({ try stream.next() }, names: ["dimension", "sheetData"]) { tag in
                if tag.localName == "dimension", let ref = tag.attribute("ref"), let range = CellRange(ref) {
                    summary.declaredRange = range
                    summary.declaredCellCount = range.size.rows * range.size.cols
                }
                return false
            }
            if options.countCells {
                var cells = 0, rows = 0
                let whole = try zip.stream(part)
                try TagScanner.scan({ try whole.next() }, names: ["c", "row", "sheetData"]) { tag in
                    switch tag.localName {
                    case "c" where !tag.isEnd: cells += 1
                    case "row" where !tag.isEnd: rows += 1
                    case "sheetData" where tag.isEnd: return false
                    default: break
                    }
                    return true
                }
                summary.countedCellCount = cells
                summary.rowCount = rows
            }
            sheets.append(summary)
        }

        var producer = SourceInfo(format: format)
        if let app = rootRels.first(where: { $0.type.hasSuffix(WorkbookReader.relApp) }).map({ WorkbookReader.resolvePart($0.target, relativeTo: "") }),
           zip.contains(app) {
            let ap = AppPropertiesParser()
            try? ap.run(try zip.read(app), part: app)
            producer.application = ap.application; producer.version = ap.version
        }
        let expanded = zip.entries.values.reduce(0) { $0 + $1.uncompressedSize }
        return WorkbookSummary(format: format, sheets: sheets, producer: producer, expandedBytes: expanded, partCount: zip.entries.count)
    }
}
