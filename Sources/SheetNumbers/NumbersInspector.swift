import Foundation
import SheetCore

/// Answers `Workbook.inspect` for a Numbers document. Every table model names its own row and column counts, so
/// a sheet's size is read from the object graph without touching the cell tiles' contents — though the package's
/// archives are decoded to find them, which is most of what a read costs before the cells themselves.
package enum NumbersInspector {
    package static func inspect(_ data: Data, options: InspectOptions) throws -> WorkbookSummary {
        let doc = try NumbersDocument(data: data, limits: options.limits)
        let reader = NumbersReader(doc: doc, options: ReadOptions(limits: options.limits))
        guard let document = doc.object(NumbersDocument.documentID), document.typeName == "TN.DocumentArchive" else {
            throw SheetError.malformedPart(path: "Index/Document.iwa", detail: "object 1 is not a TN.DocumentArchive")
        }
        var sheets: [SheetSummary] = []
        for sid in document.references("sheets") {
            guard let archive = doc.object(sid) else { continue }
            let isSheet = doc.typeName(sid) == "TN.SheetArchive"
            var summary = SheetSummary(name: archive.string("name") ?? archive.message("super")?.string("name") ?? "Sheet \(sheets.count + 1)")
            guard isSheet else { summary.isGrid = false; summary.tableCount = 0; sheets.append(summary); continue }
            let models = reader.tableModels(inSheet: sid)
            summary.tableCount = models.count
            var total = 0
            var ranges: [CellRange] = []
            for tid in models {
                guard let model = doc.object(tid) else { continue }
                let rows = model.int("number_of_rows") ?? 0, cols = model.int("number_of_columns") ?? 0
                total += rows * cols
                if rows > 0, cols > 0 { ranges.append(CellRange(minRow: 0, minCol: 0, maxRow: rows - 1, maxCol: cols - 1)) }
            }
            summary.declaredCellCount = total
            if ranges.count == 1 { summary.declaredRange = ranges[0]; summary.rowCount = ranges[0].size.rows }
            sheets.append(summary)
        }
        let zip = try ZipArchive(data: data, limits: options.limits)
        let expanded = zip.entries.values.reduce(0) { $0 + $1.uncompressedSize }
        return WorkbookSummary(format: .numbers, sheets: sheets, producer: reader.sourceInfo(), expandedBytes: expanded, partCount: zip.entries.count)
    }
}
