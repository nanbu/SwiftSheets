import Foundation

/// Assembles the package the way openpyxl does: docProps, worksheets, sharedStrings, styles, workbook, rels, manifest.
/// Theme is omitted (explicit colors do not need it); Excel, Numbers, LibreOffice and openpyxl all accept that.
enum WorkbookWriter {
    static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    static let nsMain = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let nsRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let nsPkgRel = "http://schemas.openxmlformats.org/package/2006/relationships"

    static func write(_ wb: Workbook) throws -> Data {
        guard !wb.worksheets.isEmpty else { throw SheetsError(.invalid, "a workbook needs at least one sheet") }
        var zip = ZipWriter()
        let styles = StyleRegistry()
        let strings = SharedStringTable()

        // Sheets first: they register styles and strings.
        var sheetParts: [(xml: String, rels: String?)] = []
        for ws in wb.worksheets { sheetParts.append(sheetXML(ws, epoch: wb.epoch, styles: styles, strings: strings)) }

        // [Content_Types].xml
        var ct = xmlHeader + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        ct += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        ct += "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        for i in wb.worksheets.indices { ct += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }
        ct += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        if !strings.isEmpty { ct += "<Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/>" }
        ct += "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
        ct += "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/></Types>"
        zip.add("[Content_Types].xml", Data(ct.utf8))

        zip.add("_rels/.rels", Data((xmlHeader + "<Relationships xmlns=\"\(nsPkgRel)\"><Relationship Id=\"rId1\" Type=\"\(nsRel)/officeDocument\" Target=\"xl/workbook.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/><Relationship Id=\"rId3\" Type=\"\(nsRel)/extended-properties\" Target=\"docProps/app.xml\"/></Relationships>").utf8))
        zip.add("docProps/app.xml", Data((xmlHeader + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>SwiftSheets</Application><AppVersion>0.1</AppVersion></Properties>").utf8))
        zip.add("docProps/core.xml", Data((xmlHeader + coreXML(wb.properties)).utf8))

        var wbx = xmlHeader + "<workbook xmlns=\"\(nsMain)\" xmlns:r=\"\(nsRel)\">"
        wbx += wb.epoch == .mac1904 ? "<workbookPr date1904=\"1\"/>" : "<workbookPr/>"
        wbx += "<bookViews><workbookView activeTab=\"\(wb.activeIndex)\"/></bookViews><sheets>"
        for (i, ws) in wb.worksheets.enumerated() {
            wbx += "<sheet name=\"\(XML.esc(ws.title))\" sheetId=\"\(i + 1)\"\(ws.state == .visible ? "" : " state=\"\(ws.state.rawValue)\"") r:id=\"rId\(i + 1)\"/>"
        }
        wbx += "</sheets>"
        if !wb.definedNames.isEmpty {
            wbx += "<definedNames>" + wb.definedNames.keys.sorted().map { "<definedName name=\"\(XML.esc($0))\">\(XML.esc(wb.definedNames[$0]!))</definedName>" }.joined() + "</definedNames>"
        }
        wbx += "<calcPr calcId=\"124519\" fullCalcOnLoad=\"1\"/></workbook>"
        zip.add("xl/workbook.xml", Data(wbx.utf8))

        var rels = xmlHeader + "<Relationships xmlns=\"\(nsPkgRel)\">"
        for i in wb.worksheets.indices { rels += "<Relationship Id=\"rId\(i + 1)\" Type=\"\(nsRel)/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>" }
        var next = wb.worksheets.count + 1
        rels += "<Relationship Id=\"rId\(next)\" Type=\"\(nsRel)/styles\" Target=\"styles.xml\"/>"; next += 1
        if !strings.isEmpty { rels += "<Relationship Id=\"rId\(next)\" Type=\"\(nsRel)/sharedStrings\" Target=\"sharedStrings.xml\"/>" }
        rels += "</Relationships>"
        zip.add("xl/_rels/workbook.xml.rels", Data(rels.utf8))

        for (i, part) in sheetParts.enumerated() {
            zip.add("xl/worksheets/sheet\(i + 1).xml", Data((xmlHeader + part.xml).utf8))
            if let r = part.rels { zip.add("xl/worksheets/_rels/sheet\(i + 1).xml.rels", Data((xmlHeader + r).utf8)) }
        }
        if !strings.isEmpty { zip.add("xl/sharedStrings.xml", Data((xmlHeader + strings.xml()).utf8)) }
        zip.add("xl/styles.xml", Data((xmlHeader + styles.xml()).utf8))
        return zip.finish()
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
        if let t = p.lastModifiedBy { s += "<cp:lastModifiedBy>\(XML.esc(t))</cp:lastModifiedBy>" }
        s += "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(created)</dcterms:created><dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(modified)</dcterms:modified></cp:coreProperties>"
        return s
    }

    /// Worksheet XML in the element order the schema requires (what openpyxl's WorksheetWriter emits).
    static func sheetXML(_ ws: Worksheet, epoch: DateEpoch, styles: StyleRegistry, strings: SharedStringTable) -> (xml: String, rels: String?) {
        var s = "<worksheet xmlns=\"\(nsMain)\" xmlns:r=\"\(nsRel)\">"
        s += "<sheetPr>"
        if let tc = ws.properties.tabColor { s += StyleRegistry.colorXML("tabColor", tc) }
        s += "<outlinePr summaryBelow=\"\(ws.properties.summaryBelow ? 1 : 0)\" summaryRight=\"\(ws.properties.summaryRight ? 1 : 0)\"/><pageSetUpPr/></sheetPr>"
        s += "<dimension ref=\"\(ws.cells.isEmpty ? "A1" : ws.dimensions)\"/>"
        s += "<sheetViews><sheetView workbookViewId=\"0\"\(ws.view.showGridLines ? "" : " showGridLines=\"0\"")\(ws.view.zoomScale != 100 ? " zoomScale=\"\(ws.view.zoomScale)\"" : "")\(ws.view.tabSelected ? " tabSelected=\"1\"" : "")>"
        if let f = ws.freezePanes {
            s += "<pane xSplit=\"\(f.column - 1)\" ySplit=\"\(f.row - 1)\" topLeftCell=\"\(f)\" activePane=\"bottomRight\" state=\"frozen\"/>"
            s += "<selection pane=\"topRight\"/><selection pane=\"bottomLeft\"/><selection pane=\"bottomRight\" activeCell=\"A1\" sqref=\"A1\"/>"
        } else {
            s += "<selection activeCell=\"A1\" sqref=\"A1\"/>"
        }
        s += "</sheetView></sheetViews><sheetFormatPr baseColWidth=\"8\" defaultRowHeight=\"15\"/>"
        let cols = ws.columnDimensions.compactMap { k, v -> (Int, ColumnDimension)? in v.isDefault ? nil : CellReference.columnIndex(k).map { ($0, v) } }.sorted { $0.0 < $1.0 }
        if !cols.isEmpty {
            s += "<cols>"
            for (c, d) in cols {
                s += "<col min=\"\(c)\" max=\"\(c)\""
                if let w = d.width { s += " width=\"\(XML.num(w))\" customWidth=\"1\"" }
                s += "\(XML.attr("hidden", d.hidden))\(XML.attr("bestFit", d.bestFit))"
                if d.outlineLevel > 0 { s += " outlineLevel=\"\(d.outlineLevel)\"" }
                s += "\(XML.attr("collapsed", d.collapsed))/>"
            }
            s += "</cols>"
        }
        s += "<sheetData>"
        var byRow: [Int: [Cell]] = [:]
        for (ref, c) in ws.cells { byRow[ref.row, default: []].append(c) }
        let rowNumbers = Set(byRow.keys).union(ws.rowDimensions.filter { !$0.value.isDefault }.keys).sorted()
        var hyperlinks: [(String, Hyperlink)] = []
        for r in rowNumbers {
            s += "<row r=\"\(r)\""
            if let d = ws.rowDimensions[r] {
                if let h = d.height { s += " ht=\"\(XML.num(h))\" customHeight=\"1\"" }
                s += XML.attr("hidden", d.hidden)
                if d.outlineLevel > 0 { s += " outlineLevel=\"\(d.outlineLevel)\"" }
                s += XML.attr("collapsed", d.collapsed)
            }
            s += ">"
            for c in (byRow[r] ?? []).sorted(by: { $0.column < $1.column }) {
                let styleIndex = styles.index(for: c.style)
                let st = styleIndex != 0 ? " s=\"\(styleIndex)\"" : ""
                let ref = c.coordinate
                if let h = c.hyperlink { hyperlinks.append((ref, h)) }
                switch c.value {
                case nil: s += "<c r=\"\(ref)\"\(st)/>"
                case .integer(let i)?: s += "<c r=\"\(ref)\"\(st)><v>\(i)</v></c>"
                case .number(let d)?: s += "<c r=\"\(ref)\"\(st)><v>\(XML.num(d))</v></c>"
                case .bool(let b)?: s += "<c r=\"\(ref)\"\(st) t=\"b\"><v>\(b ? 1 : 0)</v></c>"
                case .date(let dt)?: s += "<c r=\"\(ref)\"\(st)><v>\(XML.num(ExcelDate.toSerial(dt, epoch: epoch)))</v></c>"
                case .time(let t)?: s += "<c r=\"\(ref)\"\(st)><v>\(t.dayFraction)</v></c>"
                case .error(let e)?: s += "<c r=\"\(ref)\"\(st) t=\"e\"><v>\(XML.esc(e))</v></c>"
                case .formula(let f, let cached)?:
                    let body = f.hasPrefix("=") ? String(f.dropFirst()) : f
                    var cv = ""
                    var t = ""
                    if let cached = cached?.value {
                        switch cached {
                        case .string(let str): cv = "<v>\(XML.esc(str))</v>"; t = " t=\"str\""
                        case .richText(let runs): cv = "<v>\(XML.esc(runs.map(\.text).joined()))</v>"; t = " t=\"str\""
                        case .bool(let b): cv = "<v>\(b ? 1 : 0)</v>"; t = " t=\"b\""
                        case .integer(let i): cv = "<v>\(i)</v>"
                        case .number(let d): cv = "<v>\(XML.num(d))</v>"
                        case .date(let dt): cv = "<v>\(XML.num(ExcelDate.toSerial(dt, epoch: epoch)))</v>"
                        case .error(let e): cv = "<v>\(XML.esc(e))</v>"; t = " t=\"e\""
                        default: break
                        }
                    }
                    s += "<c r=\"\(ref)\"\(st)\(t)><f>\(XML.esc(body))</f>\(cv)</c>"
                case .string(let str)?:
                    s += "<c r=\"\(ref)\"\(st) t=\"s\"><v>\(strings.index(for: .string(str)))</v></c>"
                case .richText(let runs)?:
                    s += "<c r=\"\(ref)\"\(st) t=\"s\"><v>\(strings.index(for: .richText(runs)))</v></c>"
                }
            }
            s += "</row>"
        }
        s += "</sheetData>"
        if let af = ws.autoFilter { s += "<autoFilter ref=\"\(af)\"/>" }
        if !ws.mergedCells.isEmpty {
            s += "<mergeCells count=\"\(ws.mergedCells.count)\">" + ws.mergedCells.map { "<mergeCell ref=\"\($0)\"/>" }.joined() + "</mergeCells>"
        }
        var rels: String?
        if !hyperlinks.isEmpty {
            s += "<hyperlinks>"
            var r = "<Relationships xmlns=\"\(nsPkgRel)\">"
            for (i, (ref, h)) in hyperlinks.enumerated() {
                if h.isInternal { s += "<hyperlink ref=\"\(ref)\" location=\"\(XML.esc(h.target))\"\(XML.attr("tooltip", h.tooltip))/>" }
                else {
                    s += "<hyperlink ref=\"\(ref)\" r:id=\"rId\(i + 1)\"\(XML.attr("tooltip", h.tooltip))/>"
                    r += "<Relationship Id=\"rId\(i + 1)\" Type=\"\(nsRel)/hyperlink\" Target=\"\(XML.esc(h.target))\" TargetMode=\"External\"/>"
                }
            }
            s += "</hyperlinks>"
            rels = r + "</Relationships>"
        }
        let m = ws.pageMargins
        s += "<pageMargins left=\"\(XML.num(m.left))\" right=\"\(XML.num(m.right))\" top=\"\(XML.num(m.top))\" bottom=\"\(XML.num(m.bottom))\" header=\"\(XML.num(m.header))\" footer=\"\(XML.num(m.footer))\"/>"
        let p = ws.pageSetup
        if p != PageSetup() {
            s += "<pageSetup\(XML.attr("orientation", p.orientation?.rawValue))\(XML.attr("paperSize", p.paperSize))\(XML.attr("scale", p.scale))\(XML.attr("fitToWidth", p.fitToWidth))\(XML.attr("fitToHeight", p.fitToHeight))/>"
        }
        s += "</worksheet>"
        return (s, rels)
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
        var s = "<sst xmlns=\"\(WorkbookWriter.nsMain)\" count=\"\(items.count)\" uniqueCount=\"\(items.count)\">"
        for v in items {
            switch v {
            case .string(let str): s += "<si><t\(preserve(str))>\(XML.esc(str))</t></si>"
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
