import Foundation
import SheetCore

enum XMLWriter {
    static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    static let nsMain = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let nsRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let nsPkgRel = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let nsContentTypes = "http://schemas.openxmlformats.org/package/2006/content-types"

    /// Root attributes: the source's declarations (namespaces, `mc:Ignorable`) plus ours where missing.
    static func rootAttributes(_ preserved: [String: String], defaults: [String: String]) -> String {
        var attrs = preserved
        for (k, v) in defaults where attrs[k] == nil { attrs[k] = v }
        let keys = attrs.keys.sorted { a, b in
            let ax = a == "xmlns" ? 0 : a.hasPrefix("xmlns:") ? 1 : 2, bx = b == "xmlns" ? 0 : b.hasPrefix("xmlns:") ? 1 : 2
            return ax != bx ? ax < bx : a < b
        }
        return keys.map { " \($0)=\"\(XML.esc(attrs[$0]!))\"" }.joined()
    }

    /// Merges generated elements and preserved fragments into schema order (stable: fragments keep their relative order).
    static func ordered(_ generated: [(String, String)], fragments: [XMLFragment], order: [String]) -> String {
        var position: [String: Int] = [:]
        for (i, n) in order.enumerated() { position[n] = i }
        let unknown = order.count - 1   // just before extLst, which is always last
        var items: [(Int, Int, String)] = []
        for (i, (name, xml)) in generated.enumerated() { items.append((position[name] ?? unknown, i, xml)) }
        for (i, f) in fragments.enumerated() { items.append((position[f.element] ?? unknown, generated.count + i, f.xml)) }
        return items.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.2).joined()
    }

    static func num(_ d: Decimal) -> String { "\(d)" }
}

/// Collects what the write could not express.
final class WarningSink {
    var warnings: [ConversionWarning] = []
    func add(_ kind: ConversionWarning.Kind, sheet: String? = nil, at location: CellRef? = nil, _ message: String) {
        warnings.append(ConversionWarning(kind, sheet: sheet, location: location, message: message))
    }
}

/// Assembles the package: docProps, worksheets, sharedStrings, styles, workbook, rels, content types — and re-packs
/// every preserved part with its relationships (spec §7.3). Theme is omitted for new workbooks (explicit colours do
/// not need it) and preserved as an opaque part for workbooks read from a file.
enum WorkbookWriter {
    static let workbookOrder = ["fileVersion", "fileSharing", "workbookPr", "workbookProtection", "bookViews", "sheets", "functionGroups", "externalReferences", "definedNames", "calcPr", "oleSize", "customWorkbookViews", "pivotCaches", "smartTagPr", "smartTagTypes", "webPublishing", "fileRecoveryPr", "webPublishObjects", "extLst"]
    static let worksheetOrder = ["sheetPr", "dimension", "sheetViews", "sheetFormatPr", "cols", "sheetData", "sheetCalcPr", "sheetProtection", "protectedRanges", "scenarios", "autoFilter", "sortState", "dataConsolidate", "customSheetViews", "mergeCells", "phoneticPr", "conditionalFormatting", "dataValidations", "hyperlinks", "printOptions", "pageMargins", "pageSetup", "headerFooter", "rowBreaks", "colBreaks", "customProperties", "cellWatches", "ignoredErrors", "smartTags", "drawing", "legacyDrawing", "legacyDrawingHF", "drawingHF", "picture", "oleObjects", "controls", "webPublishItems", "tableParts", "extLst"]
    static let ctWorkbook = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"
    static let ctWorkbookMacro = "application/vnd.ms-excel.sheet.macroEnabled.main+xml"

    static func write(_ wb: Workbook, format: SheetFormat, options: WriteOptions) throws -> WriteResult {
        guard !wb.sheets.isEmpty else { throw SheetError.invalidWorkbook("a workbook needs at least one sheet") }
        let sink = WarningSink()
        var archive = ZipWriter()
        let preserved = wb.preserved
        let sameFamily = preserved.sourceFormat == .xlsx || preserved.sourceFormat == .xlsm
        let styles = StyleRegistry(seed: sameFamily ? preserved.styleTables : nil)
        styles.indexedColors = wb.indexedColors
        if sameFamily { styles.fragments = preserved.styleFragments }
        let strings = SharedStringTable()

        // opaque parts that travel along (VBA only into .xlsm)
        var opaque = sameFamily ? preserved.opaqueParts : [:]
        var droppedRelTypes: [String] = []
        if format == .xlsx {
            let vba = opaque.keys.filter { $0.hasSuffix("vbaProject.bin") || $0.hasSuffix("vbaProjectSignature.bin") || $0.hasSuffix("vbaData.xml") }
            if !vba.isEmpty {
                for k in vba { opaque[k] = nil }
                droppedRelTypes = ["/vbaProject", "/vbaProjectSignature"]
                sink.add(.dropped, "VBA project dropped: macros cannot be kept in .xlsx (write .xlsm to keep them)")
            }
        }
        if !sameFamily, !preserved.opaqueParts.isEmpty {
            sink.add(.dropped, "\(preserved.opaqueParts.count) part(s) preserved from the \(preserved.sourceFormat?.rawValue ?? "source") file cannot be carried into XLSX")
        }

        // sheet part paths and workbook relationship ids: existing ones are immutable, new ones follow the maximum
        let wbRels = sameFamily ? (preserved.relationships["xl/workbook.xml"] ?? []).filter { r in !droppedRelTypes.contains { r.type.hasSuffix($0) } } : []
        var usedIds = Set(wbRels.map(\.id))
        var nextId = (wbRels.compactMap(\.number).max() ?? 0) + 1
        func freshId() -> String { while usedIds.contains("rId\(nextId)") { nextId += 1 }; let id = "rId\(nextId)"; usedIds.insert(id); nextId += 1; return id }
        var usedPaths = Set(opaque.keys)
        var usedSheetIds = Set<Int>()
        struct SheetPlan { let path: String; let rId: String; let sheetId: Int }
        var plans: [SheetPlan] = []
        for sheet in wb.sheets {
            var path = sheet.preserved.partPath.flatMap { sameFamily && !usedPaths.contains($0) ? $0 : nil }
            if path == nil { var n = 1; while usedPaths.contains("xl/worksheets/sheet\(n).xml") { n += 1 }; path = "xl/worksheets/sheet\(n).xml" }
            usedPaths.insert(path!)
            var rId = sheet.preserved.relationshipId.flatMap { sameFamily && !usedIds.contains($0) ? $0 : nil }
            if let r = rId { usedIds.insert(r) } else { rId = freshId() }
            var sheetId = sheet.preserved.sheetId.flatMap { sameFamily && !usedSheetIds.contains($0) ? $0 : nil }
            if sheetId == nil { sheetId = (usedSheetIds.max() ?? 0) + 1; while usedSheetIds.contains(sheetId!) { sheetId! += 1 } }
            usedSheetIds.insert(sheetId!)
            plans.append(SheetPlan(path: path!, rId: rId!, sheetId: sheetId!))
        }

        // sheets first: they register styles and strings
        var sheetParts: [(xml: String, rels: String?)] = []
        for (i, sheet) in wb.sheets.enumerated() {
            sheetParts.append(sheetXML(sheet, epoch: wb.epoch, styles: styles, strings: strings, preserve: sameFamily, isActive: i == wb.activeIndex, sink: sink))
        }
        let stylesId = freshId()
        let sstId = strings.isEmpty ? nil : freshId()

        // [Content_Types].xml
        var defaults = ["rels": "application/vnd.openxmlformats-package.relationships+xml", "xml": "application/xml"]
        if sameFamily { for (k, v) in preserved.contentTypeDefaults where defaults[k] == nil { defaults[k] = v } }
        var overrides: [String: String] = [:]
        overrides["xl/workbook.xml"] = format == .xlsm ? ctWorkbookMacro : ctWorkbook
        for p in plans { overrides[p.path] = "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml" }
        overrides["xl/styles.xml"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"
        if !strings.isEmpty { overrides["xl/sharedStrings.xml"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml" }
        overrides["docProps/core.xml"] = "application/vnd.openxmlformats-package.core-properties+xml"
        overrides["docProps/app.xml"] = "application/vnd.openxmlformats-officedocument.extended-properties+xml"
        if sameFamily { for (k, v) in preserved.contentTypeOverrides where opaque[k] != nil { overrides[k] = v } }
        var ct = XMLWriter.header + "<Types xmlns=\"\(XMLWriter.nsContentTypes)\">"
        for k in defaults.keys.sorted() { ct += "<Default Extension=\"\(XML.esc(k))\" ContentType=\"\(XML.esc(defaults[k]!))\"/>" }
        for k in overrides.keys.sorted() { ct += "<Override PartName=\"/\(XML.esc(k))\" ContentType=\"\(XML.esc(overrides[k]!))\"/>" }
        ct += "</Types>"
        archive.add("[Content_Types].xml", Data(ct.utf8))

        // _rels/.rels
        let rootPreserved = sameFamily ? (preserved.relationships["_rels/.rels"] ?? []).filter { opaque[WorkbookReader.resolvePart($0.target, relativeTo: "")] != nil || $0.targetMode == "External" } : []
        var rootNext = (rootPreserved.compactMap(\.number).max() ?? 0) + 1
        var rootRels = XMLWriter.header + "<Relationships xmlns=\"\(XMLWriter.nsPkgRel)\">"
        for r in rootPreserved { rootRels += relationshipXML(r) }
        rootRels += "<Relationship Id=\"rId\(rootNext)\" Type=\"\(XMLWriter.nsRel)/officeDocument\" Target=\"xl/workbook.xml\"/>"; rootNext += 1
        rootRels += "<Relationship Id=\"rId\(rootNext)\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"; rootNext += 1
        rootRels += "<Relationship Id=\"rId\(rootNext)\" Type=\"\(XMLWriter.nsRel)/extended-properties\" Target=\"docProps/app.xml\"/></Relationships>"
        archive.add("_rels/.rels", Data(rootRels.utf8))
        archive.add("docProps/app.xml", Data((XMLWriter.header + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>SwiftSheets</Application><AppVersion>0.2</AppVersion></Properties>").utf8))
        archive.add("docProps/core.xml", Data((XMLWriter.header + coreXML(wb.metadata)).utf8))

        // xl/workbook.xml
        var generated: [(String, String)] = []
        var pr = sameFamily ? preserved.workbookPrAttributes : [:]
        if wb.epoch == .mac1904 { pr["date1904"] = "1" } else { pr["date1904"] = nil }
        if let cn = wb.codeName { pr["codeName"] = cn }
        generated.append(("workbookPr", "<workbookPr" + pr.keys.sorted().map { " \($0)=\"\(XML.esc(pr[$0]!))\"" }.joined() + "/>"))
        generated.append(("bookViews", "<bookViews><workbookView activeTab=\"\(wb.activeIndex)\"/></bookViews>"))
        var sheetsXML = "<sheets>"
        for (sheet, plan) in zip(wb.sheets, plans) {
            sheetsXML += "<sheet name=\"\(XML.esc(sheet.name))\" sheetId=\"\(plan.sheetId)\"\(sheet.state == .visible ? "" : " state=\"\(sheet.state.rawValue)\"") r:id=\"\(plan.rId)\"/>"
        }
        generated.append(("sheets", sheetsXML + "</sheets>"))
        var names: [String] = wb.definedNames.keys.sorted().map { "<definedName name=\"\(XML.esc($0))\">\(XML.esc(wb.definedNames[$0]!))</definedName>" }
        for (i, sheet) in wb.sheets.enumerated() {
            var local = sheet.definedNames
            if let t = sheet.printTitles { local["_xlnm.Print_Titles"] = t }
            if !sheet.printArea.isEmpty { local["_xlnm.Print_Area"] = sheet.printAreaFormula }
            if let af = sheet.autoFilter { local["_xlnm._FilterDatabase"] = "\(CellRef.quoteSheetName(sheet.name))!\(af.absoluteA1)" }
            for k in local.keys.sorted() {
                names.append("<definedName name=\"\(XML.esc(k))\" localSheetId=\"\(i)\"\(k == "_xlnm._FilterDatabase" ? " hidden=\"1\"" : "")>\(XML.esc(local[k]!))</definedName>")
            }
        }
        if !names.isEmpty { generated.append(("definedNames", "<definedNames>" + names.joined() + "</definedNames>")) }
        generated.append(("calcPr", "<calcPr calcId=\"124519\" fullCalcOnLoad=\"1\"/>"))
        let wbFragments = sameFamily ? preserved.workbookFragments.filter { $0.element != "calcPr" } : []
        var wbx = XMLWriter.header + "<workbook" + XMLWriter.rootAttributes(sameFamily ? preserved.workbookRootAttributes : [:], defaults: ["xmlns": XMLWriter.nsMain, "xmlns:r": XMLWriter.nsRel]) + ">"
        wbx += XMLWriter.ordered(generated, fragments: wbFragments, order: workbookOrder)
        wbx += "</workbook>"
        archive.add("xl/workbook.xml", Data(wbx.utf8))

        // xl/_rels/workbook.xml.rels
        var rels = XMLWriter.header + "<Relationships xmlns=\"\(XMLWriter.nsPkgRel)\">"
        for plan in plans { rels += "<Relationship Id=\"\(plan.rId)\" Type=\"\(XMLWriter.nsRel)/worksheet\" Target=\"\(XML.esc(relativeTarget(plan.path, from: "xl")))\"/>" }
        rels += "<Relationship Id=\"\(stylesId)\" Type=\"\(XMLWriter.nsRel)/styles\" Target=\"styles.xml\"/>"
        if let sstId { rels += "<Relationship Id=\"\(sstId)\" Type=\"\(XMLWriter.nsRel)/sharedStrings\" Target=\"sharedStrings.xml\"/>" }
        for r in wbRels where r.targetMode == "External" || opaque[WorkbookReader.resolvePart(r.target, relativeTo: "xl")] != nil { rels += relationshipXML(r) }
        rels += "</Relationships>"
        archive.add("xl/_rels/workbook.xml.rels", Data(rels.utf8))

        for (part, plan) in zip(sheetParts, plans) {
            archive.add(plan.path, Data((XMLWriter.header + part.xml).utf8))
            if let r = part.rels { archive.add(WorkbookReader.relsPath(of: plan.path), Data((XMLWriter.header + r).utf8)) }
        }
        if !strings.isEmpty { archive.add("xl/sharedStrings.xml", Data((XMLWriter.header + strings.xml()).utf8)) }
        archive.add("xl/styles.xml", Data((XMLWriter.header + styles.xml()).utf8))
        for name in opaque.keys.sorted() { archive.add(name, opaque[name]!) }

        let warnings = sink.warnings
        return WriteResult(data: archive.finish(), warnings: warnings, suggestion: WriteResult.suggest(from: warnings, target: format, options: options))
    }

    static func relationshipXML(_ r: Relationship) -> String {
        "<Relationship Id=\"\(XML.esc(r.id))\" Type=\"\(XML.esc(r.type))\" Target=\"\(XML.esc(r.target))\"\(XML.attr("TargetMode", r.targetMode))/>"
    }

    /// "xl/worksheets/sheet1.xml" relative to "xl" → "worksheets/sheet1.xml".
    static func relativeTarget(_ path: String, from base: String) -> String {
        path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : "/" + path
    }

    static func coreXML(_ p: DocumentProperties) -> String {
        let f = ISO8601DateFormatter()
        let created = f.string(from: p.created ?? Date(timeIntervalSince1970: 1_767_225_600))  // 2026-01-01 when unset (reproducible output)
        let modified = f.string(from: p.modified ?? p.created ?? Date(timeIntervalSince1970: 1_767_225_600))
        var s = "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
        if let t = p.title { s += "<dc:title>\(XML.esc(t))</dc:title>" }
        if let t = p.subject { s += "<dc:subject>\(XML.esc(t))</dc:subject>" }
        s += "<dc:creator>\(XML.esc(p.creator))</dc:creator>"
        if let t = p.description { s += "<dc:description>\(XML.esc(t))</dc:description>" }
        if let t = p.identifier { s += "<dc:identifier>\(XML.esc(t))</dc:identifier>" }
        if let t = p.language { s += "<dc:language>\(XML.esc(t))</dc:language>" }
        s += "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(created)</dcterms:created><dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(modified)</dcterms:modified>"
        if let t = p.lastModifiedBy { s += "<cp:lastModifiedBy>\(XML.esc(t))</cp:lastModifiedBy>" }
        if let t = p.category { s += "<cp:category>\(XML.esc(t))</cp:category>" }
        if let t = p.contentStatus { s += "<cp:contentStatus>\(XML.esc(t))</cp:contentStatus>" }
        if let t = p.version { s += "<cp:version>\(XML.esc(t))</cp:version>" }
        if let t = p.revision { s += "<cp:revision>\(XML.esc(t))</cp:revision>" }
        if let t = p.keywords { s += "<cp:keywords>\(XML.esc(t))</cp:keywords>" }
        if let t = p.lastPrinted { s += "<cp:lastPrinted>\(f.string(from: t))</cp:lastPrinted>" }
        s += "</cp:coreProperties>"
        return s
    }

    /// Serial / text of any value for `<v>`, with the `t` attribute it needs.
    static func valueXML(_ v: CellValue, epoch: DateEpoch, strings: SharedStringTable, inline: Bool) -> (t: String, body: String) {
        switch v {
        case .integer(let i): return ("", "<v>\(i)</v>")
        case .number(let d): return ("", "<v>\(XMLWriter.num(d))</v>")
        case .bool(let b): return (" t=\"b\"", "<v>\(b ? 1 : 0)</v>")
        case .date(let dt): return ("", "<v>\(XML.num(ExcelDate.toSerial(dt, epoch: epoch)))</v>")
        case .time(let t): return ("", "<v>\(t.dayFraction)</v>")
        case .duration(let d): return ("", "<v>\(XML.num(ExcelDate.toSerial(d)))</v>")
        case .error(let e): return (" t=\"e\"", "<v>\(XML.esc(e))</v>")
        case .text(let s):
            if inline { return (" t=\"str\"", "<v>\(XML.esc(s))</v>") }
            return (" t=\"s\"", "<v>\(strings.index(for: .text(s)))</v>")
        case .richText(let runs):
            if inline { return (" t=\"str\"", "<v>\(XML.esc(runs.map(\.text).joined()))</v>") }
            return (" t=\"s\"", "<v>\(strings.index(for: .richText(runs)))</v>")
        case .formula: return ("", "")
        }
    }

    /// Worksheet XML in schema order, with the sheet's preserved fragments merged in at their positions.
    static func sheetXML(_ ws: Sheet, epoch: DateEpoch, styles: StyleRegistry, strings: SharedStringTable, preserve: Bool, isActive: Bool, sink: WarningSink) -> (xml: String, rels: String?) {
        let table = ws.table
        var generated: [(String, String)] = []
        var s = "<sheetPr\(XML.attr("codeName", ws.properties.codeName))\(ws.properties.filterMode.map { " filterMode=\"\($0 ? 1 : 0)\"" } ?? "")>"
        if let tc = ws.properties.tabColor { s += StyleRegistry.colorXML("tabColor", tc) }
        s += "<outlinePr summaryBelow=\"\(ws.properties.summaryBelow ? 1 : 0)\" summaryRight=\"\(ws.properties.summaryRight ? 1 : 0)\"/>"
        s += "<pageSetUpPr\(ws.properties.fitToPage.map { " fitToPage=\"\($0 ? 1 : 0)\"" } ?? "")/></sheetPr>"
        generated.append(("sheetPr", s))
        generated.append(("dimension", "<dimension ref=\"\(table.dimensions)\"/>"))
        s = "<sheetViews><sheetView workbookViewId=\"0\"\(ws.view.showGridLines ? "" : " showGridLines=\"0\"")\(ws.view.zoomScale != 100 ? " zoomScale=\"\(ws.view.zoomScale)\"" : "")\(ws.view.tabSelected || isActive ? " tabSelected=\"1\"" : "")>"
        if let f = ws.freezePanes {
            s += "<pane xSplit=\"\(f.col)\" ySplit=\"\(f.row)\" topLeftCell=\"\(f.a1)\" activePane=\"bottomRight\" state=\"frozen\"/>"
            s += "<selection pane=\"topRight\"/><selection pane=\"bottomLeft\"/><selection pane=\"bottomRight\" activeCell=\"\(XML.esc(ws.view.activeCell))\" sqref=\"\(XML.esc(ws.view.sqref))\"/>"
        } else {
            s += "<selection activeCell=\"\(XML.esc(ws.view.activeCell))\" sqref=\"\(XML.esc(ws.view.sqref))\"/>"
        }
        generated.append(("sheetViews", s + "</sheetView></sheetViews>"))
        let sf = ws.sheetFormat
        generated.append(("sheetFormatPr", "<sheetFormatPr baseColWidth=\"\(sf.baseColWidth)\"\(sf.defaultColWidth.map { " defaultColWidth=\"\(XML.num($0))\"" } ?? "") defaultRowHeight=\"\(XML.num(sf.defaultRowHeight))\"\(XML.attr("customHeight", sf.customHeight))\(XML.attr("zeroHeight", sf.zeroHeight))/>"))
        let cols = table.columnDimensions.filter { !$0.value.isDefault }.sorted { $0.key < $1.key }
        if !cols.isEmpty {
            s = "<cols>"
            for (c, d) in cols {
                s += "<col min=\"\(c + 1)\" max=\"\(c + 1)\""
                if let w = d.width { s += " width=\"\(XML.num(w))\" customWidth=\"1\"" }
                s += "\(XML.attr("hidden", d.hidden))\(XML.attr("bestFit", d.bestFit))"
                if d.outlineLevel > 0 { s += " outlineLevel=\"\(d.outlineLevel)\"" }
                if let st = d.style { s += " style=\"\(styles.index(for: st))\"" }
                s += "\(XML.attr("collapsed", d.collapsed))/>"
            }
            generated.append(("cols", s + "</cols>"))
        }
        s = "<sheetData>"
        var byRow: [Int: [(CellRef, Cell)]] = [:]
        for (ref, c) in table.cells { byRow[ref.row, default: []].append((ref, c)) }
        let rowNumbers = Set(byRow.keys).union(table.rowDimensions.filter { !$0.value.isDefault }.keys).sorted()
        var hyperlinks: [(String, Hyperlink)] = []
        for r in rowNumbers {
            s += "<row r=\"\(r + 1)\""
            if let d = table.rowDimensions[r] {
                if let h = d.height { s += " ht=\"\(XML.num(h))\" customHeight=\"1\"" }
                s += XML.attr("hidden", d.hidden)
                if d.outlineLevel > 0 { s += " outlineLevel=\"\(d.outlineLevel)\"" }
                s += XML.attr("collapsed", d.collapsed)
                if let st = d.style { s += " s=\"\(styles.index(for: st))\" customFormat=\"1\"" }
                s += XML.attr("thickTop", d.thickTop) + XML.attr("thickBot", d.thickBottom)
            }
            s += ">"
            for (ref, c) in (byRow[r] ?? []).sorted(by: { $0.0.col < $1.0.col }) {
                let styleIndex = styles.index(for: c.style)
                let st = styleIndex != 0 ? " s=\"\(styleIndex)\"" : ""
                let a1 = ref.a1
                if let h = c.hyperlink { hyperlinks.append((a1, h)) }
                if c.comment != nil { sink.add(.dropped, sheet: ws.name, at: ref, "cell notes are not written yet (they need a VML part)") }
                switch c.value {
                case nil: s += "<c r=\"\(a1)\"\(st)/>"
                case .formula(let f, let cached)?:
                    if case .unparsed(_, let dialect) = f, dialect != .xlsx {
                        sink.add(.degraded, sheet: ws.name, at: ref, "formula in \(dialect.rawValue) dialect could not be translated; cached value written")
                        if let cached {
                            let (t, body) = valueXML(cached, epoch: epoch, strings: strings, inline: false)
                            s += "<c r=\"\(a1)\"\(st)\(t)>\(body)</c>"
                        } else { s += "<c r=\"\(a1)\"\(st)/>" }
                        continue
                    }
                    var t = "", cv = ""
                    if let cached { (t, cv) = valueXML(cached, epoch: epoch, strings: strings, inline: true) }
                    s += "<c r=\"\(a1)\"\(st)\(t)><f>\(XML.esc(f.rendered(as: .xlsx)))</f>\(cv)</c>"
                case let v?:
                    let (t, body) = valueXML(v, epoch: epoch, strings: strings, inline: false)
                    s += "<c r=\"\(a1)\"\(st)\(t)>\(body)</c>"
                }
            }
            s += "</row>"
        }
        generated.append(("sheetData", s + "</sheetData>"))
        let fragments = preserve ? ws.preserved.fragments : []
        let hasFilterFragment = fragments.contains { $0.element == "autoFilter" }
        if let af = ws.autoFilter, !hasFilterFragment { generated.append(("autoFilter", "<autoFilter ref=\"\(af.a1)\"/>")) }
        if !table.merges.isEmpty {
            generated.append(("mergeCells", "<mergeCells count=\"\(table.merges.count)\">" + table.merges.map { "<mergeCell ref=\"\($0.a1)\"/>" }.joined() + "</mergeCells>"))
        }
        // sheet relationships: preserved ones keep their ids; hyperlinks are numbered after them
        let preservedRels = preserve ? ws.preserved.relationships : []
        var rels: String?
        var relXML = "<Relationships xmlns=\"\(XMLWriter.nsPkgRel)\">" + preservedRels.map(relationshipXML).joined()
        if !hyperlinks.isEmpty {
            var next = (preservedRels.compactMap(\.number).max() ?? 0) + 1
            let used = Set(preservedRels.map(\.id))
            s = "<hyperlinks>"
            for (a1, h) in hyperlinks {
                if h.isInternal { s += "<hyperlink ref=\"\(a1)\" location=\"\(XML.esc(h.target))\"\(XML.attr("display", h.display))\(XML.attr("tooltip", h.tooltip))/>" }
                else {
                    while used.contains("rId\(next)") { next += 1 }
                    s += "<hyperlink ref=\"\(a1)\" r:id=\"rId\(next)\"\(XML.attr("display", h.display))\(XML.attr("tooltip", h.tooltip))/>"
                    relXML += "<Relationship Id=\"rId\(next)\" Type=\"\(XMLWriter.nsRel)/hyperlink\" Target=\"\(XML.esc(h.target))\" TargetMode=\"External\"/>"
                    next += 1
                }
            }
            generated.append(("hyperlinks", s + "</hyperlinks>"))
        }
        if !preservedRels.isEmpty || relXML.contains("/hyperlink") { rels = relXML + "</Relationships>" }
        let po = ws.printOptions
        if po != PrintOptions() {
            generated.append(("printOptions", "<printOptions\(XML.attr("horizontalCentered", po.horizontalCentered))\(XML.attr("verticalCentered", po.verticalCentered))\(XML.attr("headings", po.headings))\(XML.attr("gridLines", po.gridLines))/>"))
        }
        let m = ws.pageMargins
        generated.append(("pageMargins", "<pageMargins left=\"\(XML.num(m.left))\" right=\"\(XML.num(m.right))\" top=\"\(XML.num(m.top))\" bottom=\"\(XML.num(m.bottom))\" header=\"\(XML.num(m.header))\" footer=\"\(XML.num(m.footer))\"/>"))
        let p = ws.pageSetup
        if p != PageSetup() {
            generated.append(("pageSetup", "<pageSetup\(XML.attr("orientation", p.orientation?.rawValue))\(XML.attr("paperSize", p.paperSize))\(XML.attr("scale", p.scale))\(XML.attr("fitToWidth", p.fitToWidth))\(XML.attr("fitToHeight", p.fitToHeight))\(XML.attr("firstPageNumber", p.firstPageNumber))\(p.useFirstPageNumber.map { " useFirstPageNumber=\"\($0 ? 1 : 0)\"" } ?? "")/>"))
        }
        var xml = "<worksheet" + XMLWriter.rootAttributes(preserve ? ws.preserved.rootAttributes : [:], defaults: ["xmlns": XMLWriter.nsMain, "xmlns:r": XMLWriter.nsRel]) + ">"
        xml += XMLWriter.ordered(generated, fragments: fragments, order: worksheetOrder)
        xml += "</worksheet>"
        return (xml, rels)
    }
}

/// The shared string table (deduped), written as sharedStrings.xml with rich runs where present.
final class SharedStringTable {
    private var items: [CellValue] = []
    private var index: [CellValue: Int] = [:]
    var isEmpty: Bool { items.isEmpty }

    func index(for value: CellValue) -> Int {
        if let i = index[value] { return i }
        items.append(value)
        index[value] = items.count - 1
        return items.count - 1
    }

    func xml() -> String {
        var s = "<sst xmlns=\"\(XMLWriter.nsMain)\" count=\"\(items.count)\" uniqueCount=\"\(items.count)\">"
        for v in items {
            switch v {
            case .text(let str): s += "<si><t\(preserve(str))>\(XML.esc(str))</t></si>"
            case .richText(let runs):
                s += "<si>"
                for r in runs {
                    s += "<r>"
                    if let f = r.font { s += StyleRegistry.fontXML(f, tag: "rPr", nameTag: "rFont") }
                    s += "<t\(preserve(r.text))>\(XML.esc(r.text))</t></r>"
                }
                s += "</si>"
            default: s += "<si><t></t></si>"
            }
        }
        return s + "</sst>"
    }

    private func preserve(_ t: String) -> String {
        (t.hasPrefix(" ") || t.hasSuffix(" ") || t.hasPrefix("　") || t.hasSuffix("　") || t.contains("\n") || t.contains("\t")) ? " xml:space=\"preserve\"" : ""
    }
}
