import Foundation
import SheetCore

/// The two parts that make a pivot table — `xl/pivotTables/pivotTableN.xml` and the
/// `xl/pivotCache/pivotCacheDefinitionN.xml` it reads — parsed into the model and written back out of it.
///
/// Everything the model does not carry is kept: unknown attributes of the two root elements, unknown children as
/// XML fragments, and the `pivotCacheRecords` part as bytes. For a *new* pivot table SwiftSheets writes a cache
/// that says `saveData="0" refreshOnLoad="1"` and has no record part at all — it lays a pivot table out rather than
/// computing one, so the application reads the source range when it opens the file (spec appendix B.15).
enum PivotParts {
    static let ctTable = "application/vnd.openxmlformats-officedocument.spreadsheetml.pivotTable+xml"
    static let ctCacheDefinition = "application/vnd.openxmlformats-officedocument.spreadsheetml.pivotCacheDefinition+xml"
    static let ctCacheRecords = "application/vnd.openxmlformats-officedocument.spreadsheetml.pivotCacheRecords+xml"
    static let relTable = "/pivotTable"
    static let relCacheDefinition = "/pivotCacheDefinition"
    static let relCacheRecords = "/pivotCacheRecords"

    static let tableOrder = ["location", "pivotFields", "rowFields", "rowItems", "colFields", "colItems",
                             "pageFields", "dataFields", "formats", "conditionalFormats", "chartFormats",
                             "pivotHierarchies", "pivotTableStyleInfo", "filters", "rowHierarchiesUsage",
                             "colHierarchiesUsage", "extLst"]
    static let cacheOrder = ["cacheSource", "cacheFields", "cacheHierarchies", "kpis", "tupleCache",
                             "calculatedItems", "calculatedMembers", "dimensions", "measureGroups", "maps", "extLst"]

    // MARK: - Writing

    /// `xl/pivotTables/pivotTableN.xml`.
    static func tableXML(_ p: PivotTable, cacheId: Int) -> String {
        var s = "<pivotTableDefinition xmlns=\"\(XMLWriter.nsMain)\" name=\"\(XML.esc(p.name))\" cacheId=\"\(cacheId)\""
        s += " applyNumberFormats=\"0\" applyBorderFormats=\"0\" applyFontFormats=\"0\" applyPatternFormats=\"0\""
        s += " applyAlignmentFormats=\"0\" applyWidthHeightFormats=\"1\""
        s += " dataCaption=\"\(XML.esc(p.dataCaption))\" updatedVersion=\"8\" minRefreshableVersion=\"3\" createdVersion=\"8\""
        s += " itemPrintTitles=\"1\" useAutoFormatting=\"1\" indent=\"0\" outline=\"1\" outlineData=\"1\" multipleFieldFilters=\"0\""
        if !p.showRowGrandTotals { s += " rowGrandTotals=\"0\"" }
        if !p.showColumnGrandTotals { s += " colGrandTotals=\"0\"" }
        for k in p.otherAttributes.keys.sorted() { s += XML.attr(k, p.otherAttributes[k]) }
        s += ">"

        var generated: [(String, String)] = []
        let l = p.location
        var loc = "<location ref=\"\(l.ref.a1)\" firstHeaderRow=\"\(l.firstHeaderRow)\" firstDataRow=\"\(l.firstDataRow)\" firstDataCol=\"\(l.firstDataCol)\""
        loc += XML.attr("rowPageCount", l.rowPageCount) + XML.attr("colPageCount", l.columnPageCount) + "/>"
        generated.append(("location", loc))

        var fields = "<pivotFields count=\"\(p.fields.count)\">"
        for f in p.fields {
            fields += "<pivotField"
            fields += XML.attr("axis", f.axis?.rawValue)
            fields += XML.attr("dataField", f.isDataField)
            fields += XML.attr("showAll", f.showAll)
            if !f.defaultSubtotal { fields += " defaultSubtotal=\"0\"" }
            for k in f.otherAttributes.keys.sorted() { fields += XML.attr(k, f.otherAttributes[k]) }
            guard !f.items.isEmpty else { fields += "/>"; continue }
            fields += "><items count=\"\(f.items.count)\">"
            for item in f.items {
                fields += "<item"
                fields += XML.attr("x", item.index) + XML.attr("t", item.itemType) + XML.attr("h", item.hidden)
                fields += "/>"
            }
            fields += "</items></pivotField>"
        }
        generated.append(("pivotFields", fields + "</pivotFields>"))

        if !p.rowFields.isEmpty {
            generated.append(("rowFields", "<rowFields count=\"\(p.rowFields.count)\">"
                + p.rowFields.map { "<field x=\"\($0)\"/>" }.joined() + "</rowFields>"))
        }
        if !p.columnFields.isEmpty {
            generated.append(("colFields", "<colFields count=\"\(p.columnFields.count)\">"
                + p.columnFields.map { "<field x=\"\($0)\"/>" }.joined() + "</colFields>"))
        }
        if !p.pageFields.isEmpty {
            generated.append(("pageFields", "<pageFields count=\"\(p.pageFields.count)\">"
                + p.pageFields.map { "<pageField fld=\"\($0.field)\"\(XML.attr("item", $0.item))\(XML.attr("name", $0.name)) hier=\"-1\"/>" }.joined()
                + "</pageFields>"))
        }
        if !p.dataFields.isEmpty {
            var x = "<dataFields count=\"\(p.dataFields.count)\">"
            for d in p.dataFields {
                x += "<dataField\(XML.attr("name", d.name)) fld=\"\(d.field)\""
                if d.function != .sum { x += " subtotal=\"\(d.function.rawValue)\"" }
                x += XML.attr("showDataAs", d.showDataAs) + XML.attr("baseField", d.baseField) + XML.attr("baseItem", d.baseItem)
                x += XML.attr("numFmtId", d.numberFormatID) + "/>"
            }
            generated.append(("dataFields", x + "</dataFields>"))
        }
        if let info = p.styleInfo {
            generated.append(("pivotTableStyleInfo", "<pivotTableStyleInfo\(XML.attr("name", info.name))"
                + " showRowHeaders=\"\(info.showRowHeaders ? 1 : 0)\" showColHeaders=\"\(info.showColumnHeaders ? 1 : 0)\""
                + " showRowStripes=\"\(info.showRowStripes ? 1 : 0)\" showColStripes=\"\(info.showColumnStripes ? 1 : 0)\""
                + " showLastColumn=\"\(info.showLastColumn ? 1 : 0)\"/>"))
        }
        s += XMLWriter.ordered(generated, fragments: p.fragments, order: tableOrder)
        return s + "</pivotTableDefinition>"
    }

    /// `xl/pivotCache/pivotCacheDefinitionN.xml`.
    static func cacheDefinitionXML(_ c: PivotCache, recordsRelationshipId: String?) -> String {
        var s = "<pivotCacheDefinition xmlns=\"\(XMLWriter.nsMain)\" xmlns:r=\"\(XMLWriter.nsRel)\""
        if let id = recordsRelationshipId { s += " r:id=\"\(id)\"" }
        s += " refreshedBy=\"\(XML.esc(c.refreshedBy ?? SwiftSheetsInfo.name))\""
        s += " recordCount=\"\(c.recordCount ?? 0)\""
        s += " createdVersion=\"8\" refreshedVersion=\"8\" minRefreshableVersion=\"3\""
        if c.refreshOnLoad { s += " refreshOnLoad=\"1\"" }
        // no record part means no saved rows; the application reads the source range when it opens the file
        if recordsRelationshipId == nil { s += " saveData=\"0\"" }
        for k in c.otherAttributes.keys.sorted() { s += XML.attr(k, c.otherAttributes[k]) }
        s += ">"

        var generated: [(String, String)] = []
        var src = "<cacheSource type=\"worksheet\"><worksheetSource"
        if let name = c.sourceName { src += " name=\"\(XML.esc(name))\"" }
        else { src += " ref=\"\(c.sourceRef.a1)\"" }
        src += " sheet=\"\(XML.esc(c.sourceSheet))\"/></cacheSource>"
        generated.append(("cacheSource", src))

        var fields = "<cacheFields count=\"\(c.fields.count)\">"
        for f in c.fields {
            fields += "<cacheField name=\"\(XML.esc(f.name))\" numFmtId=\"\(f.numberFormatID ?? 0)\">"
            var attrs = f.sharedItemAttributes
            if attrs.isEmpty, f.sharedItems.isEmpty { attrs["containsSemiMixedTypes"] = "0"; attrs["containsString"] = "0" }
            fields += "<sharedItems"
            for k in attrs.keys.sorted() { fields += XML.attr(k, attrs[k]) }
            if !f.sharedItems.isEmpty { fields += " count=\"\(f.sharedItems.count)\"" }
            fields += f.sharedItems.isEmpty ? "/>" : ">" + f.sharedItems.map(itemXML).joined() + "</sharedItems>"
            fields += "</cacheField>"
        }
        generated.append(("cacheFields", fields + "</cacheFields>"))
        s += XMLWriter.ordered(generated, fragments: c.fragments, order: cacheOrder)
        return s + "</pivotCacheDefinition>"
    }

    static func itemXML(_ item: PivotItem) -> String {
        switch item {
        case .text(let v): "<s v=\"\(XML.esc(v))\"/>"
        case .number(let v): "<n v=\"\(XML.num(v))\"/>"
        case .bool(let v): "<b v=\"\(v ? 1 : 0)\"/>"
        case .date(let v): "<d v=\"\(v.iso8601)\"/>"
        case .error(let v): "<e v=\"\(XML.esc(v))\"/>"
        case .missing: "<m/>"
        }
    }

}

/// xl/pivotTables/pivotTableN.xml → a `PivotTable` without its cache (the reader attaches that).
final class PivotTableParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    static let knownAttributes: Set<String> = ["name", "cacheId", "dataCaption", "rowGrandTotals", "colGrandTotals"]
    static let knownChildren: Set<String> = ["location", "pivotFields", "rowFields", "colFields", "pageFields",
                                             "dataFields", "pivotTableStyleInfo"]
    var table: PivotTable?
    var cacheId: Int?
    private var depth = 0
    private var field: PivotField?
    private var inRowFields = false, inColFields = false

    func start(_ name: String, _ a: [String: String]) {
        depth += 1
        if depth == 1 {
            cacheId = Int(a["cacheId"] ?? "")
            var t = PivotTable(name: a["name"] ?? "PivotTable", location: PivotLocation(ref: CellRange(CellRef(row: 0, col: 0))),
                               fields: [], cache: PivotCache(sourceRef: CellRange(CellRef(row: 0, col: 0)), sourceSheet: "", fields: []),
                               dataCaption: a["dataCaption"] ?? "Values",
                               showRowGrandTotals: XMLBool.isNotFalse(a["rowGrandTotals"]),
                               showColumnGrandTotals: XMLBool.isNotFalse(a["colGrandTotals"]),
                               styleInfo: nil)
            t.otherAttributes = a.filter { !PivotTableParser.knownAttributes.contains($0.key) && !$0.key.hasPrefix("xmlns") }
            table = t
            return
        }
        if depth == 2, !PivotTableParser.knownChildren.contains(name) { beginCapture(); return }
        switch name {
        case "location":
            guard let ref = a["ref"].flatMap(CellRange.init) else { return }
            table?.location = PivotLocation(ref: ref, firstHeaderRow: Int(a["firstHeaderRow"] ?? "1") ?? 1,
                                            firstDataRow: Int(a["firstDataRow"] ?? "2") ?? 2,
                                            firstDataCol: Int(a["firstDataCol"] ?? "1") ?? 1,
                                            rowPageCount: Int(a["rowPageCount"] ?? ""),
                                            columnPageCount: Int(a["colPageCount"] ?? ""))
        case "pivotField":
            var f = PivotField(name: a["name"], axis: a["axis"].flatMap(PivotField.Axis.init(rawValue:)),
                               isDataField: XMLBool.isTrue(a["dataField"]), showAll: XMLBool.isTrue(a["showAll"]),
                               defaultSubtotal: XMLBool.isNotFalse(a["defaultSubtotal"]))
            f.otherAttributes = a.filter { !["name", "axis", "dataField", "showAll", "defaultSubtotal"].contains($0.key) }
            field = f
        case "item" where field != nil:
            field!.items.append(PivotFieldItem(index: Int(a["x"] ?? ""), itemType: a["t"], hidden: XMLBool.isTrue(a["h"])))
        case "rowFields": inRowFields = true
        case "colFields": inColFields = true
        case "field":
            guard let x = Int(a["x"] ?? "") else { return }
            if inRowFields { table?.rowFields.append(x) } else if inColFields { table?.columnFields.append(x) }
        case "pageField":
            guard let fld = Int(a["fld"] ?? "") else { return }
            table?.pageFields.append(PivotPageField(field: fld, item: Int(a["item"] ?? ""), name: a["name"]))
        case "dataField":
            guard let fld = Int(a["fld"] ?? "") else { return }
            table?.dataFields.append(PivotDataField(field: fld,
                                                    function: PivotDataField.Function(rawValue: a["subtotal"] ?? "sum") ?? .sum,
                                                    name: a["name"], numberFormatID: Int(a["numFmtId"] ?? ""),
                                                    showDataAs: a["showDataAs"], baseField: Int(a["baseField"] ?? ""),
                                                    baseItem: Int(a["baseItem"] ?? "")))
        case "pivotTableStyleInfo":
            table?.styleInfo = PivotStyleInfo(name: a["name"], showRowHeaders: XMLBool.isTrue(a["showRowHeaders"]),
                                              showColumnHeaders: XMLBool.isTrue(a["showColHeaders"]),
                                              showRowStripes: XMLBool.isTrue(a["showRowStripes"]),
                                              showColumnStripes: XMLBool.isTrue(a["showColStripes"]),
                                              showLastColumn: XMLBool.isTrue(a["showLastColumn"]))
        default: break
        }
    }
    func end(_ name: String) {
        depth -= 1
        switch name {
        case "pivotField": if let f = field { table?.fields.append(f) }; field = nil
        case "rowFields": inRowFields = false
        case "colFields": inColFields = false
        default: break
        }
    }
    func captured(_ fragment: XMLFragment) { depth -= 1; table?.fragments.append(fragment) }
}

/// xl/pivotCache/pivotCacheDefinitionN.xml → a `PivotCache`.
final class PivotCacheParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    static let knownAttributes: Set<String> = ["refreshOnLoad", "recordCount", "refreshedBy", "r:id"]
    static let knownChildren: Set<String> = ["cacheSource", "cacheFields"]
    var cache = PivotCache(sourceRef: CellRange(CellRef(row: 0, col: 0)), sourceSheet: "", fields: [])
    var recordsRelationshipId: String?
    private var depth = 0
    private var cacheField: PivotCacheField?
    private var inSharedItems = false

    func start(_ name: String, _ a: [String: String]) {
        depth += 1
        if depth == 1 {
            cache.refreshOnLoad = XMLBool.isTrue(a["refreshOnLoad"])
            cache.recordCount = Int(a["recordCount"] ?? "")
            cache.refreshedBy = a["refreshedBy"]
            recordsRelationshipId = a["r:id"] ?? a.first { $0.key.hasSuffix(":id") }?.value
            cache.otherAttributes = a.filter {
                !PivotCacheParser.knownAttributes.contains($0.key) && !$0.key.hasPrefix("xmlns") && !$0.key.hasSuffix(":id")
            }
            return
        }
        if depth == 2, !PivotCacheParser.knownChildren.contains(name) { beginCapture(); return }
        switch name {
        case "worksheetSource":
            if let ref = a["ref"].flatMap(CellRange.init) { cache.sourceRef = ref }
            cache.sourceName = a["name"]
            cache.sourceSheet = a["sheet"] ?? ""
        case "cacheField": cacheField = PivotCacheField(name: a["name"] ?? "", numberFormatID: Int(a["numFmtId"] ?? ""))
        case "sharedItems" where cacheField != nil:
            inSharedItems = true
            cacheField!.sharedItemAttributes = a.filter { $0.key != "count" }
        case "s" where inSharedItems: cacheField!.sharedItems.append(.text(a["v"] ?? ""))
        case "n" where inSharedItems: cacheField!.sharedItems.append(.number(Double(a["v"] ?? "") ?? 0))
        case "b" where inSharedItems: cacheField!.sharedItems.append(.bool(XMLBool.isTrue(a["v"])))
        case "e" where inSharedItems: cacheField!.sharedItems.append(.error(a["v"] ?? ""))
        case "m" where inSharedItems: cacheField!.sharedItems.append(.missing)
        case "d" where inSharedItems:
            if case .date(let dt)? = ExcelDate.fromISO8601(a["v"] ?? "") { cacheField!.sharedItems.append(.date(dt)) }
            else { cacheField!.sharedItems.append(.text(a["v"] ?? "")) }
        default: break
        }
    }
    func end(_ name: String) {
        depth -= 1
        switch name {
        case "sharedItems": inSharedItems = false
        case "cacheField": if let f = cacheField { cache.fields.append(f) }; cacheField = nil
        default: break
        }
    }
    func captured(_ fragment: XMLFragment) { depth -= 1; cache.fragments.append(fragment) }
}
