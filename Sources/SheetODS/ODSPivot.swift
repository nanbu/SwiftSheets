import Foundation
import SheetCore

/// Pivot tables in ODF — "data pilots" — both ways.
///
/// The two formats agree on the shape: a source range, and one entry per source column saying where that column
/// goes (down the side, across the top, into the body, or into the filters above) and how the body is summarised.
/// They disagree on everything around it. ODF names a field by its **header text**, not by its position; it has no
/// cache of the source's distinct values; and it keeps the layout of the drawn table in `table:target-range-address`
/// rather than in the field entries.
///
/// The limit is the same one the XLSX writer already states: **SwiftSheets lays a pivot table out, it does not
/// compute one.** The application recomputes from the source range when it opens the file.
enum ODSPivot {
    /// `PivotDataField.Function` ⇄ `table:function`. ODF has no product, count-numbers or population variants
    /// under those names, so they fall back to the nearest thing and the writer says so.
    static func function(_ f: PivotDataField.Function) -> (name: String, exact: Bool) {
        switch f {
        case .sum: return ("sum", true)
        case .count: return ("count", true)
        case .average: return ("average", true)
        case .max: return ("max", true)
        case .min: return ("min", true)
        case .product: return ("product", true)
        case .countNums: return ("countnums", true)
        case .stdDev: return ("stdev", true)
        case .stdDevp: return ("stdevp", true)
        case .var: return ("var", true)
        case .varp: return ("varp", true)
        }
    }
    static func excelFunction(_ name: String) -> PivotDataField.Function {
        switch name.lowercased() {
        case "count": return .count
        case "average": return .average
        case "max": return .max
        case "min": return .min
        case "product": return .product
        case "countnums": return .countNums
        case "stdev": return .stdDev
        case "stdevp": return .stdDevp
        case "var": return .var
        case "varp": return .varp
        default: return .sum
        }
    }

    // MARK: - Model → ODF

    static func xml(_ wb: Workbook, sink: ODSWarningSink) -> String {
        var out = ""
        for sheet in wb.sheets {
            for pivot in sheet.pivotTables {
                out += table(pivot, on: sheet.name, sink: sink)
            }
        }
        return out.isEmpty ? "" : "<table:data-pilot-tables>\(out)</table:data-pilot-tables>"
    }

    private static func table(_ pivot: PivotTable, on sheetName: String, sink: ODSWarningSink) -> String {
        let prefix = String(ODSWriter.odsSheetPrefix(sheetName).dropFirst())
        let sourcePrefix = String(ODSWriter.odsSheetPrefix(pivot.cache.sourceSheet).dropFirst())
        let ref = pivot.location.ref
        let target = "\(prefix).\(ref.topLeft.a1):\(prefix).\(ref.bottomRight.a1)"
        let source = "\(sourcePrefix).\(pivot.cache.sourceRef.topLeft.a1):\(sourcePrefix).\(pivot.cache.sourceRef.bottomRight.a1)"

        // the cells that carry a field's drop-down button: one per row field along the header row, one per column
        // field down the left of it — which is how LibreOffice writes them
        var buttons: [String] = []
        let headerRow = ref.minRow + pivot.location.firstHeaderRow
        for (i, _) in pivot.rowFields.enumerated() where pivot.rowFields[i] != PivotTable.valuesField {
            buttons.append("\(prefix).\(CellRef(row: headerRow + 1, col: ref.minCol + i).a1)")
        }
        for (i, _) in pivot.columnFields.enumerated() where pivot.columnFields[i] != PivotTable.valuesField {
            buttons.append("\(prefix).\(CellRef(row: headerRow, col: ref.minCol + pivot.location.firstDataCol + i - 1).a1)")
        }

        var s = "<table:data-pilot-table table:name=\"\(XML.esc(pivot.name))\" table:application-data=\"\""
        s += " table:target-range-address=\"\(XML.esc(target))\""
        if !buttons.isEmpty { s += " table:buttons=\"\(XML.esc(buttons.joined(separator: " ")))\"" }
        s += " table:show-filter-button=\"\(!pivot.pageFields.isEmpty)\""
        s += " table:drill-down-on-double-click=\"false\">"
        s += "<table:source-cell-range table:cell-range-address=\"\(XML.esc(source))\"/>"

        for (index, cached) in pivot.cache.fields.enumerated() {
            let orientation: String
            let function: String
            var displayName: String?
            if let data = pivot.dataFields.first(where: { $0.field == index }) {
                orientation = "data"
                let mapped = ODSPivot.function(data.function)
                function = mapped.name
                displayName = data.name ?? "\(data.function.caption) / \(cached.name)"
            } else if pivot.pageFields.contains(where: { $0.field == index }) {
                orientation = "page"; function = "auto"
            } else if pivot.rowFields.contains(index) {
                orientation = "row"; function = "auto"
            } else if pivot.columnFields.contains(index) {
                orientation = "column"; function = "auto"
            } else {
                orientation = "hidden"; function = "auto"
            }
            s += "<table:data-pilot-field table:source-field-name=\"\(XML.esc(cached.name))\""
            if let displayName { s += " tableooo:display-name=\"\(XML.esc(displayName))\"" }
            s += " table:orientation=\"\(orientation)\" table:used-hierarchy=\"-1\" table:function=\"\(function)\">"
            s += "<table:data-pilot-level table:show-empty=\"\(pivot.fields.indices.contains(index) && pivot.fields[index].showAll)\">"
            s += "<table:data-pilot-subtotals><table:data-pilot-subtotal table:function=\"auto\"/></table:data-pilot-subtotals>"
            s += "</table:data-pilot-level></table:data-pilot-field>"
        }
        s += "</table:data-pilot-table>"

        if pivot.styleInfo != nil {
            sink.add(.degraded, subject: .objects, sheet: sheetName,
                     "pivot table \(pivot.name): its banded look is not carried into ODF, which has no pivot style")
        }
        sink.add(.degraded, subject: .objects, sheet: sheetName,
                 "pivot table \(pivot.name) is written as an ODF data pilot: the layout travels, the numbers are recomputed when the file is opened")
        return s
    }

    // MARK: - ODF → model

    /// One `table:data-pilot-table` as read, before it is placed on its sheet.
    struct Parsed {
        var name = ""
        var target: CellRange?
        var source: CellRange?
        var fields: [(name: String, orientation: String, function: String, displayName: String?)] = []
    }

    /// Turns a parsed data pilot into the model's pivot table. Nil when it names no source.
    static func pivotTable(_ p: Parsed) -> PivotTable? {
        guard let target = p.target, var source = p.source, let sourceSheet = source.sheet, !p.fields.isEmpty else { return nil }
        source.sheet = nil
        var location = target
        location.sheet = nil
        var cacheFields: [PivotCacheField] = []
        var fields: [PivotField] = []
        var rowFields: [Int] = [], columnFields: [Int] = [], pageFields: [PivotPageField] = []
        var dataFields: [PivotDataField] = []
        for (index, entry) in p.fields.enumerated() {
            cacheFields.append(PivotCacheField(name: entry.name))
            var field = PivotField()
            switch entry.orientation {
            case "row": field.axis = .row; rowFields.append(index)
            case "column": field.axis = .column; columnFields.append(index)
            case "page": field.axis = .page; pageFields.append(PivotPageField(field: index))
            case "data":
                field.isDataField = true
                dataFields.append(PivotDataField(field: index, function: excelFunction(entry.function), name: entry.displayName))
            default: break
            }
            fields.append(field)
        }
        guard !dataFields.isEmpty || !rowFields.isEmpty || !columnFields.isEmpty else { return nil }
        // more than one value needs a place for the captions, which ODF does not record
        if dataFields.count > 1, !columnFields.contains(PivotTable.valuesField) { columnFields.append(PivotTable.valuesField) }
        let cache = PivotCache(sourceRef: source, sourceSheet: sourceSheet, fields: cacheFields)
        return PivotTable(name: p.name.isEmpty ? "PivotTable1" : p.name,
                          location: PivotLocation(ref: location), fields: fields, cache: cache,
                          rowFields: rowFields, columnFields: columnFields, pageFields: pageFields,
                          dataFields: dataFields, styleInfo: nil)
    }
}
