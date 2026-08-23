import Foundation
import SheetCore

/// Collects what the write could not express.
final class ODSWarningSink {
    var warnings: [ConversionWarning] = []
    func add(_ kind: ConversionWarning.Kind, subject: ConversionWarning.Subject = .other, sheet: String? = nil,
             at location: CellRef? = nil, _ message: String) {
        warnings.append(ConversionWarning(kind, subject: subject, sheet: sheet, location: location, message: message))
    }
}

/// The automatic styles of content.xml: column / row / table / cell / data styles, deduplicated by value.
final class ODSStyleRegistry {
    private var columns: [String: String] = [:]
    private(set) var columnOrder: [(name: String, width: String)] = []
    private var rows: [Double: String] = [:]
    private(set) var rowOrder: [(name: String, height: Double)] = []
    private var cells: [CellStyle: String] = [:]
    private(set) var cellOrder: [(name: String, style: CellStyle)] = []
    private var data: [String: String] = [:]
    private(set) var dataOrder: [(name: String, style: ODSDataStyle)] = []
    private(set) var fonts: [String] = []
    /// A theme / indexed colour was written as the default colour.
    private(set) var nonRGBColour = false
    /// Number-format codes with no ODF form (written without a data style) and codes written partially.
    private(set) var unexpressibleCodes: [String] = []
    private(set) var partialCodes: [String] = []
    var usesHiddenTable = false

    func column(width: Double) -> String {
        let key = ODSLength.cm(characters: width)
        if let n = columns[key] { return n }
        let n = "co\(columnOrder.count + 1)"
        columns[key] = n; columnOrder.append((n, key))
        return n
    }

    func row(height: Double) -> String {
        let key = (height * 100).rounded() / 100
        if let n = rows[key] { return n }
        let n = "ro\(rowOrder.count + 1)"
        rows[key] = n; rowOrder.append((n, key))
        return n
    }

    /// Nil for the default style (no attribute needed).
    func cell(_ style: CellStyle) -> String? {
        if style == .default { return nil }
        if let n = cells[style] { return n }
        let n = "ce\(cellOrder.count + 1)"
        cells[style] = n; cellOrder.append((n, style))
        if let name = style.font.name, !fonts.contains(name) { fonts.append(name) }
        _ = dataStyle(for: style.numberFormat)
        return n
    }

    func dataStyle(for code: String) -> String? {
        if let n = data[code] { return n.isEmpty ? nil : n }
        let (style, exact) = ODSDataStyle.from(excelCode: code)
        guard let style else {
            data[code] = ""
            if code != NumberFormat.general { unexpressibleCodes.append(code) }
            return nil
        }
        if !exact { partialCodes.append(code) }
        let n = "N\(dataOrder.count + 1)"
        data[code] = n; dataOrder.append((n, style))
        return n
    }

    func xml() -> String {
        var s = ""
        for c in columnOrder {
            s += "<style:style style:name=\"\(c.name)\" style:family=\"table-column\"><style:table-column-properties fo:break-before=\"auto\" style:column-width=\"\(c.width)\"/></style:style>"
        }
        for r in rowOrder {
            s += "<style:style style:name=\"\(r.name)\" style:family=\"table-row\"><style:table-row-properties style:row-height=\"\(ODSLength.pt(r.height))\" fo:break-before=\"auto\" style:use-optimal-row-height=\"false\"/></style:style>"
        }
        s += "<style:style style:name=\"ta1\" style:family=\"table\" style:master-page-name=\"Default\"><style:table-properties table:display=\"true\" style:writing-mode=\"lr-tb\"/></style:style>"
        if usesHiddenTable {
            s += "<style:style style:name=\"ta2\" style:family=\"table\" style:master-page-name=\"Default\"><style:table-properties table:display=\"false\" style:writing-mode=\"lr-tb\"/></style:style>"
        }
        for d in dataOrder { s += d.style.xml(name: d.name) }
        for c in cellOrder { s += cellStyleXML(c.name, c.style) }
        return s
    }

    private func cellStyleXML(_ name: String, _ st: CellStyle) -> String {
        var s = "<style:style style:name=\"\(name)\" style:family=\"table-cell\" style:parent-style-name=\"Default\""
        if let ds = data[st.numberFormat], !ds.isEmpty { s += " style:data-style-name=\"\(ds)\"" }
        s += ">"
        // cell properties
        var cell = ""
        if st.fill.patternType != .none, let fg = st.fill.foregroundColor ?? st.fill.backgroundColor {
            var nonRGB = false
            let hex = ODSColor.hex(fg, nonRGB: &nonRGB)
            if nonRGB { nonRGBColour = true } else { cell += " fo:background-color=\"\(hex)\"" }
        }
        let b = st.border
        var nonRGB = false
        if b.left == b.right, b.left == b.top, b.left == b.bottom, let v = ODSBorder.value(b.left, nonRGB: &nonRGB) { cell += " fo:border=\"\(v)\"" }
        else {
            if let v = ODSBorder.value(b.left, nonRGB: &nonRGB) { cell += " fo:border-left=\"\(v)\"" }
            if let v = ODSBorder.value(b.right, nonRGB: &nonRGB) { cell += " fo:border-right=\"\(v)\"" }
            if let v = ODSBorder.value(b.top, nonRGB: &nonRGB) { cell += " fo:border-top=\"\(v)\"" }
            if let v = ODSBorder.value(b.bottom, nonRGB: &nonRGB) { cell += " fo:border-bottom=\"\(v)\"" }
        }
        if nonRGB { nonRGBColour = true }
        let al = st.alignment
        if let v = al.vertical {
            switch v {
            case .top: cell += " style:vertical-align=\"top\""
            case .center, .justify, .distributed: cell += " style:vertical-align=\"middle\""
            case .bottom: cell += " style:vertical-align=\"bottom\""
            }
        }
        if al.wrapText { cell += " fo:wrap-option=\"wrap\"" }
        if al.shrinkToFit { cell += " style:shrink-to-fit=\"true\"" }
        if al.textRotation != 0, al.textRotation <= 180 { cell += " style:rotation-angle=\"\(al.textRotation)\"" }
        if al.horizontal != nil { cell += " style:text-align-source=\"fix\"" }
        if !st.protection.locked || st.protection.hidden {
            let p = st.protection
            cell += " style:cell-protect=\"\(p.locked ? (p.hidden ? "hidden-and-protected" : "protected") : (p.hidden ? "formula-hidden" : "none"))\""
        }
        if !cell.isEmpty { s += "<style:table-cell-properties\(cell)/>" }
        // paragraph properties
        if let h = al.horizontal {
            let v: String?
            switch h {
            case .left: v = "start"
            case .center, .centerContinuous: v = "center"
            case .right: v = "end"
            case .justify, .distributed: v = "justify"
            case .general, .fill: v = nil
            }
            if let v { s += "<style:paragraph-properties fo:text-align=\"\(v)\"/>" }
        }
        // text properties
        let f = st.font, d = Font.default
        var text = ""
        if let n = f.name, n != d.name || f.scheme == nil {
            text += " style:font-name=\"\(XML.esc(n))\" style:font-name-asian=\"\(XML.esc(n))\" style:font-name-complex=\"\(XML.esc(n))\""
        }
        if let size = f.size, size != d.size {
            let pt = ODSLength.pt(size)
            text += " fo:font-size=\"\(pt)\" style:font-size-asian=\"\(pt)\" style:font-size-complex=\"\(pt)\""
        }
        if f.bold { text += " fo:font-weight=\"bold\" style:font-weight-asian=\"bold\" style:font-weight-complex=\"bold\"" }
        if f.italic { text += " fo:font-style=\"italic\" style:font-style-asian=\"italic\" style:font-style-complex=\"italic\"" }
        switch f.color {
        case .rgb(let v)?: text += " fo:color=\"#\(Units.shortColor(v).lowercased())\""
        case .theme(1, _)?, nil, .auto?: break
        default: nonRGBColour = true
        }
        if let u = f.underline {
            text += " style:text-underline-style=\"solid\" style:text-underline-width=\"auto\" style:text-underline-color=\"font-color\""
            if u == .double || u == .doubleAccounting { text += " style:text-underline-type=\"double\"" }
        }
        if f.strikethrough { text += " style:text-line-through-style=\"solid\" style:text-line-through-type=\"single\"" }
        if !text.isEmpty { s += "<style:text-properties\(text)/>" }
        return s + "</style:style>"
    }
}

/// Writes the ODF package (spec §8): `mimetype` first and stored, manifest, content, styles, meta, settings, then the
/// preserved opaque parts.
enum ODSWriter {
    static let mimeType = "application/vnd.oasis.opendocument.spreadsheet"
    static let generator = SwiftSheetsInfo.generator
    static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    static let namespaces = [
        "office": "urn:oasis:names:tc:opendocument:xmlns:office:1.0",
        "style": "urn:oasis:names:tc:opendocument:xmlns:style:1.0",
        "text": "urn:oasis:names:tc:opendocument:xmlns:text:1.0",
        "table": "urn:oasis:names:tc:opendocument:xmlns:table:1.0",
        "draw": "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0",
        "fo": "urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0",
        "xlink": "http://www.w3.org/1999/xlink",
        "dc": "http://purl.org/dc/elements/1.1/",
        "meta": "urn:oasis:names:tc:opendocument:xmlns:meta:1.0",
        "number": "urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0",
        "svg": "urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0",
        "of": "urn:oasis:names:tc:opendocument:xmlns:of:1.2",
        "config": "urn:oasis:names:tc:opendocument:xmlns:config:1.0",
        "ooo": "http://openoffice.org/2004/office",
        "manifest": "urn:oasis:names:tc:opendocument:xmlns:manifest:1.0",
    ]
    static func ns(_ prefixes: [String]) -> String { prefixes.map { " xmlns:\($0)=\"\(namespaces[$0]!)\"" }.joined() }

    static func write(_ wb: Workbook, options: WriteOptions) throws -> WriteResult {
        guard !wb.sheets.isEmpty else { throw SheetError.invalidWorkbook("a workbook needs at least one sheet") }
        let sink = ODSWarningSink()
        let styles = ODSStyleRegistry()
        styles.usesHiddenTable = wb.sheets.contains { $0.state != .visible }

        // body first: it registers the styles
        var body = ""
        for sheet in wb.sheets { body += tableXML(sheet, styles: styles, sink: sink) }
        body += namedExpressionsXML(wb.definedNames, baseSheet: wb.sheets[0].name)
        body += databaseRangesXML(wb)

        var content = xmlHeader + "<office:document-content" + ns(["office", "style", "text", "table", "draw", "fo", "xlink", "dc", "meta", "number", "svg", "of"]) + " office:version=\"1.3\">"
        content += "<office:scripts/><office:font-face-decls>" + fontFacesXML(styles.fonts) + "</office:font-face-decls>"
        content += "<office:automatic-styles>" + styles.xml() + "</office:automatic-styles>"
        content += "<office:body><office:spreadsheet>" + body + "</office:spreadsheet></office:body></office:document-content>"

        // sheet features the ODS writer does not express (all of them read and written for XLSX; none of them
        // silently dropped)
        for sheet in wb.sheets {
            if !sheet.headerFooter.isEmpty {
                sink.add(.dropped, subject: .formatting, sheet: sheet.name, "printed header / footer dropped: it lives in a master page, which this writer does not generate")
            }
            if !sheet.rowBreaks.isEmpty || !sheet.columnBreaks.isEmpty {
                sink.add(.dropped, subject: .formatting, sheet: sheet.name, "manual page breaks dropped")
            }
            if !sheet.filterColumns.isEmpty || sheet.sortState != nil || sheet.hasUnmodelledFilters {
                sink.add(.dropped, subject: .formatting, sheet: sheet.name, "auto-filter conditions and sort state dropped: the range is written, what it lets through is not")
            }
            let arrays = sheet.tables.reduce(0) { $0 + $1.arrayFormulas.count }
            if arrays > 0 {
                sink.add(.degraded, subject: .formulas, sheet: sheet.name, "\(arrays) array formula(s) written as ordinary formulas: their range is not carried into ODS")
            }
        }

        // warnings about what the styles could not say
        if styles.nonRGBColour { sink.add(.degraded, subject: .formatting, "theme/indexed colours written as default") }
        for code in styles.unexpressibleCodes { sink.add(.substituted, subject: .formatting, "number format \(code) has no ODF data style; General used") }
        for code in styles.partialCodes { sink.add(.substituted, subject: .formatting, "number format \(code): only its first section is written") }

        // preserved parts: same-format ones travel along (unlinked); foreign ones cannot
        let preserved = wb.preserved
        var opaque: [String: Data] = [:]
        if preserved.sourceFormat == .ods {
            opaque = preserved.opaqueParts
            // only drawn content is worth a warning: metadata parts (manifest.rdf, Configurations2) are re-packed as they are
            let drawn = opaque.keys.filter { $0.hasPrefix("Pictures/") || $0.hasPrefix("Object ") || $0.hasPrefix("ObjectReplacements/") || $0.hasPrefix("media/") }
            if !drawn.isEmpty { sink.add(.dropped, subject: .objects, "\(drawn.count) embedded object(s)/picture(s) of the source ODS are not re-linked: content.xml is regenerated") }
        } else if !preserved.opaqueParts.isEmpty {
            sink.add(.dropped, subject: .objects, "\(preserved.opaqueParts.count) part(s) (charts, drawings, VBA…) cannot be carried into ODS")
        }

        var archive = ZipWriter()
        archive.add("mimetype", Data(mimeType.utf8), stored: true)
        archive.add("META-INF/manifest.xml", Data(manifestXML(opaque: opaque, mediaTypes: preserved.contentTypeOverrides).utf8))
        archive.add("content.xml", Data(content.utf8))
        archive.add("styles.xml", Data(stylesXML(styles.fonts).utf8))
        archive.add("meta.xml", Data(metaXML(wb.metadata).utf8))
        archive.add("settings.xml", Data(settingsXML(wb).utf8))
        for name in opaque.keys.sorted() { archive.add(name, opaque[name]!) }

        let warnings = sink.warnings
        return WriteResult(data: archive.finish(), warnings: warnings, suggestion: WriteResult.suggest(from: warnings, target: .ods, options: options))
    }

    // MARK: - Parts

    static func fontFacesXML(_ fonts: [String]) -> String {
        var names = fonts
        if let d = Font.default.name, !names.contains(d) { names.insert(d, at: 0) }
        return names.map { "<style:font-face style:name=\"\(XML.esc($0))\" svg:font-family=\"\(XML.esc($0.contains(" ") ? "'" + $0 + "'" : $0))\"/>" }.joined()
    }

    static func manifestXML(opaque: [String: Data], mediaTypes: [String: String]) -> String {
        var s = xmlHeader + "<manifest:manifest" + ns(["manifest"]) + " manifest:version=\"1.3\">"
        s += "<manifest:file-entry manifest:full-path=\"/\" manifest:version=\"1.3\" manifest:media-type=\"\(mimeType)\"/>"
        for p in ["content.xml", "styles.xml", "meta.xml", "settings.xml"] { s += "<manifest:file-entry manifest:full-path=\"\(p)\" manifest:media-type=\"text/xml\"/>" }
        for name in opaque.keys.sorted() {
            s += "<manifest:file-entry manifest:full-path=\"\(XML.esc(name))\" manifest:media-type=\"\(XML.esc(mediaTypes[name] ?? ""))\"/>"
        }
        return s + "</manifest:manifest>"
    }

    static func stylesXML(_ fonts: [String]) -> String {
        let d = Font.default
        var s = xmlHeader + "<office:document-styles" + ns(["office", "style", "text", "table", "fo", "svg", "number"]) + " office:version=\"1.3\">"
        s += "<office:font-face-decls>" + fontFacesXML(fonts) + "</office:font-face-decls>"
        s += "<office:styles><style:default-style style:family=\"table-cell\"><style:text-properties"
        if let n = d.name { s += " style:font-name=\"\(XML.esc(n))\" style:font-name-asian=\"\(XML.esc(n))\" style:font-name-complex=\"\(XML.esc(n))\"" }
        if let size = d.size { let pt = ODSLength.pt(size); s += " fo:font-size=\"\(pt)\" style:font-size-asian=\"\(pt)\" style:font-size-complex=\"\(pt)\"" }
        s += "/></style:default-style><style:style style:name=\"Default\" style:family=\"table-cell\"/></office:styles>"
        s += "<office:automatic-styles><style:page-layout style:name=\"pm1\"><style:page-layout-properties style:writing-mode=\"lr-tb\"/><style:header-style/><style:footer-style/></style:page-layout></office:automatic-styles>"
        s += "<office:master-styles><style:master-page style:name=\"Default\" style:page-layout-name=\"pm1\"><style:header/><style:footer/></style:master-page></office:master-styles>"
        return s + "</office:document-styles>"
    }

    static func metaXML(_ p: DocumentProperties) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let created = f.string(from: p.created ?? Date(timeIntervalSince1970: 1_767_225_600))
        let modified = f.string(from: p.modified ?? p.created ?? Date(timeIntervalSince1970: 1_767_225_600))
        var s = xmlHeader + "<office:document-meta" + ns(["office", "meta", "dc"]) + " office:version=\"1.3\"><office:meta>"
        s += "<meta:generator>\(generator)</meta:generator>"
        s += "<meta:initial-creator>\(XML.esc(p.creator))</meta:initial-creator><dc:creator>\(XML.esc(p.lastModifiedBy ?? p.creator))</dc:creator>"
        s += "<meta:creation-date>\(created)</meta:creation-date><dc:date>\(modified)</dc:date>"
        if let t = p.title { s += "<dc:title>\(XML.esc(t))</dc:title>" }
        if let t = p.subject { s += "<dc:subject>\(XML.esc(t))</dc:subject>" }
        if let t = p.description { s += "<dc:description>\(XML.esc(t))</dc:description>" }
        if let t = p.keywords { s += "<meta:keyword>\(XML.esc(t))</meta:keyword>" }
        return s + "</office:meta></office:document-meta>"
    }

    static func settingsXML(_ wb: Workbook) -> String {
        func item(_ name: String, _ type: String, _ value: String) -> String { "<config:config-item config:name=\"\(name)\" config:type=\"\(type)\">\(XML.esc(value))</config:config-item>" }
        var s = xmlHeader + "<office:document-settings" + ns(["office", "config", "ooo"]) + " office:version=\"1.3\"><office:settings>"
        s += "<config:config-item-set config:name=\"ooo:view-settings\"><config:config-item-map-indexed config:name=\"Views\"><config:config-item-map-entry>"
        s += item("ViewId", "string", "view1")
        s += "<config:config-item-map-named config:name=\"Tables\">"
        for sheet in wb.sheets {
            let f = sheet.freezePanes
            let cols = f?.col ?? 0, rows = f?.row ?? 0
            s += "<config:config-item-map-entry config:name=\"\(XML.esc(sheet.name))\">"
            s += item("CursorPositionX", "int", "0") + item("CursorPositionY", "int", "0")
            s += item("HorizontalSplitMode", "short", cols > 0 ? "2" : "0") + item("VerticalSplitMode", "short", rows > 0 ? "2" : "0")
            s += item("HorizontalSplitPosition", "int", String(cols)) + item("VerticalSplitPosition", "int", String(rows))
            s += item("ActiveSplitRange", "short", "2")
            s += item("PositionLeft", "int", "0") + item("PositionRight", "int", String(cols)) + item("PositionTop", "int", "0") + item("PositionBottom", "int", String(rows))
            s += "</config:config-item-map-entry>"
        }
        s += "</config:config-item-map-named>"
        s += item("ActiveTable", "string", wb.sheets[wb.activeIndex].name)
        s += "</config:config-item-map-entry></config:config-item-map-indexed></config:config-item-set>"
        return s + "</office:settings></office:document-settings>"
    }

    /// Workbook-scoped names go after the tables; sheet-scoped ones inside their `table:table`.
    static func namedExpressionsXML(_ names: [String: String], baseSheet: String) -> String {
        guard !names.isEmpty else { return "" }
        var s = "<table:named-expressions>"
        for name in names.keys.sorted() {
            let text = names[name]!
            let expr = FormulaExpr.parse(text, dialect: .xlsx)
            let isRange: Bool = { switch expr { case .ref, .range: return true; default: return false } }()
            if isRange {
                let address = odsAddress(expr)
                s += "<table:named-range table:name=\"\(XML.esc(name))\" table:base-cell-address=\"\(XML.esc(baseCell(address)))\" table:cell-range-address=\"\(XML.esc(address))\"/>"
            } else {
                let rendered = expr.isUnparsed ? text : String(expr.rendered(as: .ods).dropFirst(4))
                s += "<table:named-expression table:name=\"\(XML.esc(name))\" table:base-cell-address=\"\(XML.esc(odsSheetPrefix(baseSheet))).$A$1\" table:expression=\"\(XML.esc(rendered))\"/>"
            }
        }
        return s + "</table:named-expressions>"
    }

    /// Auto-filters, as the anonymous database ranges LibreOffice and Excel both understand. Child of
    /// `office:spreadsheet` after `table:named-expressions` (ODF 1.3 §9.4).
    static func databaseRangesXML(_ wb: Workbook) -> String {
        let filtered = wb.sheets.enumerated().compactMap { i, sheet in sheet.autoFilter.map { (i, sheet.name, $0) } }
        guard !filtered.isEmpty else { return "" }
        var s = "<table:database-ranges>"
        for (i, name, range) in filtered {
            let prefix = String(odsSheetPrefix(name).dropFirst())
            let address = "\(prefix).\(range.topLeft.a1):\(prefix).\(range.bottomRight.a1)"
            s += "<table:database-range table:name=\"__Anonymous_Sheet_DB__\(i)\" table:display-filter-buttons=\"true\" table:target-range-address=\"\(XML.esc(address))\"/>"
        }
        return s + "</table:database-ranges>"
    }

    /// `$Sheet1` / `$'My Sheet'` — the sheet part of an absolute ODS address.
    static func odsSheetPrefix(_ name: String) -> String {
        let simple = name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
        return "$" + (simple ? name : "'" + name.replacingOccurrences(of: "'", with: "''") + "'")
    }

    /// `'My Sheet'!$A$1:$B$2` → `$'My Sheet'.$A$1:.$B$2` (the form LibreOffice writes).
    static func odsAddress(_ expr: FormulaExpr) -> String {
        var inner = String(expr.rendered(as: .ods).dropFirst(4))   // "of:=[…]"
        if inner.hasPrefix("["), inner.hasSuffix("]") { inner = String(inner.dropFirst().dropLast()) }
        return inner.hasPrefix(".") || inner.hasPrefix("$") ? inner : "$" + inner
    }

    static func baseCell(_ address: String) -> String {
        address.split(separator: ":", maxSplits: 1).first.map(String.init) ?? address
    }

    // MARK: - Tables

    static func tableXML(_ sheet: Sheet, styles: ODSStyleRegistry, sink: ODSWarningSink) -> String {
        let t = sheet.table
        // merges: the anchor carries the span, the rest of the rectangle is written as covered cells. A merge may
        // span the whole sheet, so its positions are only materialised while they are few — past that the geometry
        // answers "is this covered?" directly, and the sheet is not grown to fit a rectangle nobody can see.
        var anchors: [CellRef: CellRange] = [:]
        var anchorRows = Set<Int>()
        var covered = Set<CellRef>()
        var coveredRows = Set<Int>()
        var wideMerges: [CellRange] = []
        var mergeMaxCol = -1, mergeMaxRow = -1
        for m in t.merges {
            anchors[m.topLeft] = m
            anchorRows.insert(m.minRow)
            let rows = m.maxRow - m.minRow + 1, cols = m.maxCol - m.minCol + 1
            if rows > 0, cols > 0, rows <= Table.maxMaterialisedMergeCells / Swift.max(cols, 1) {
                for ref in m.cells where ref != m.topLeft { covered.insert(ref); coveredRows.insert(ref.row) }
                mergeMaxCol = Swift.max(mergeMaxCol, m.maxCol); mergeMaxRow = Swift.max(mergeMaxRow, m.maxRow)
            } else {
                wideMerges.append(m)
            }
        }
        func isCovered(_ ref: CellRef) -> Bool {
            covered.contains(ref) || wideMerges.contains { $0.contains(ref) && $0.topLeft != ref }
        }
        func rowIsCovered(_ r: Int) -> Bool {
            coveredRows.contains(r) || wideMerges.contains { r >= $0.minRow && r <= $0.maxRow }
        }
        let ncols = Swift.max(1, t.columnCount, (t.columnDimensions.keys.max() ?? -1) + 1, mergeMaxCol + 1)
        let nrows = Swift.max(1, t.rowCount, (t.rowDimensions.keys.max() ?? -1) + 1, mergeMaxRow + 1)
        var s = "<table:table table:name=\"\(XML.esc(sheet.name))\" table:style-name=\"\(sheet.state == .visible ? "ta1" : "ta2")\">"

        // columns, adjacent equal ones merged
        struct ColumnSpec: Equatable { var style: String?; var hidden: Bool; var defaultCell: String? }
        var runs: [(ColumnSpec, Int)] = []
        for c in 0..<ncols {
            let d = t.columnDimensions[c]
            let spec = ColumnSpec(style: d?.width.map { styles.column(width: $0) }, hidden: d?.hidden ?? false, defaultCell: d?.style.flatMap { styles.cell($0) })
            if let last = runs.last, last.0 == spec { runs[runs.count - 1].1 += 1 } else { runs.append((spec, 1)) }
        }
        for (spec, n) in runs {
            s += "<table:table-column"
            if let st = spec.style { s += " table:style-name=\"\(st)\"" }
            if n > 1 { s += " table:number-columns-repeated=\"\(n)\"" }
            if spec.hidden { s += " table:visibility=\"collapse\"" }
            s += " table:default-cell-style-name=\"\(spec.defaultCell ?? "Default")\"/>"
        }

        // which rows hold cells; the cells themselves stay where they are (copying them into a second collection
        // costs one whole `Cell` — style included — per position)
        var rowsWithCells = Set<Int>()
        for ref in t.cells.keys { rowsWithCells.insert(ref.row) }

        var emptyRun = 0
        func flushEmpty() {
            guard emptyRun > 0 else { return }
            s += "<table:table-row\(emptyRun > 1 ? " table:number-rows-repeated=\"\(emptyRun)\"" : "")><table:table-cell\(ncols > 1 ? " table:number-columns-repeated=\"\(ncols)\"" : "")/></table:table-row>"
            emptyRun = 0
        }
        for r in 0..<nrows {
            let hasCells = rowsWithCells.contains(r)
            let dim = t.rowDimensions[r]
            guard hasCells || dim != nil || rowIsCovered(r) || anchorRows.contains(r) else { emptyRun += 1; continue }
            flushEmpty()
            s += "<table:table-row"
            if let h = dim?.height { s += " table:style-name=\"\(styles.row(height: h))\"" }
            if dim?.hidden == true { s += " table:visibility=\"collapse\"" }
            s += ">"
            var c = 0
            while c < ncols {
                let ref = CellRef(row: r, col: c)
                if isCovered(ref) {
                    var n = 1
                    while c + n < ncols, isCovered(CellRef(row: r, col: c + n)), t.cells[CellRef(row: r, col: c + n)] == nil { n += 1 }
                    s += "<table:covered-table-cell\(n > 1 ? " table:number-columns-repeated=\"\(n)\"" : "")/>"
                    c += n
                } else if let cell = t.cells[ref] ?? (anchors[ref] != nil ? Cell() : nil) {
                    // an anchor with no cell of its own still has to be written: the span hangs on it
                    s += cellXML(cell, at: ref, merge: anchors[ref], sheet: sheet.name, styles: styles, sink: sink)
                    c += 1
                } else {
                    var n = 1
                    while c + n < ncols, t.cells[CellRef(row: r, col: c + n)] == nil, anchors[CellRef(row: r, col: c + n)] == nil,
                          !isCovered(CellRef(row: r, col: c + n)) { n += 1 }
                    s += "<table:table-cell\(n > 1 ? " table:number-columns-repeated=\"\(n)\"" : "")/>"
                    c += n
                }
            }
            s += "</table:table-row>"
        }
        flushEmpty()
        s += namedExpressionsXML(sheet.definedNames, baseSheet: sheet.name)
        return s + "</table:table>"
    }

    static func cellXML(_ cell: Cell, at ref: CellRef, merge: CellRange?, sheet: String, styles: ODSStyleRegistry, sink: ODSWarningSink) -> String {
        var attrs = ""
        if let n = styles.cell(cell.style) { attrs += " table:style-name=\"\(n)\"" }
        if let m = merge, !m.isSingleCell { attrs += " table:number-columns-spanned=\"\(m.size.cols)\" table:number-rows-spanned=\"\(m.size.rows)\"" }
        var valueAttrs = ""
        var paragraphs: [String] = []
        let percent = NumberFormat.isPercentFormat(cell.style.numberFormat)
        switch cell.value {
        case nil: break
        case .formula(let f, let cached)?:
            if case .unparsed(_, let dialect) = f, dialect != .ods {
                sink.add(.degraded, subject: .formulas, sheet: sheet, at: ref, "formula in \(dialect.rawValue) dialect could not be translated; cached value written")
            } else if !f.isExpressible(in: .ods) {
                sink.add(.degraded, subject: .formulas, sheet: sheet, at: ref, "OpenFormula cannot express this formula without changing its meaning (an intersection of defined names); cached value written")
            } else {
                attrs += " table:formula=\"\(XML.esc(f.rendered(as: .ods)))\""
            }
            if let cached { (valueAttrs, paragraphs) = valueXML(cached, percent: percent) }
        case let v?: (valueAttrs, paragraphs) = valueXML(v, percent: percent)
        }
        if let h = cell.hyperlink, !paragraphs.isEmpty {
            let href = h.isInternal ? "#" + h.target.replacingOccurrences(of: "!", with: ".") : h.target
            let first = paragraphs[0].dropFirst("<text:p>".count).dropLast("</text:p>".count)
            paragraphs[0] = "<text:p><text:a xlink:href=\"\(XML.esc(href))\" xlink:type=\"simple\">\(first)</text:a></text:p>"
        }
        var s = "<table:table-cell\(attrs)\(valueAttrs)>"
        if let note = cell.comment {
            s += "<office:annotation office:display=\"false\">"
            if !note.author.isEmpty { s += "<dc:creator>\(XML.esc(note.author))</dc:creator>" }
            s += paragraphsXML(note.text).joined() + "</office:annotation>"
        }
        s += paragraphs.joined()
        return s + "</table:table-cell>"
    }

    /// The typed value attributes and the display paragraphs of a value.
    static func valueXML(_ v: CellValue, percent: Bool) -> (String, [String]) {
        switch v {
        case .text(let s): return (" office:value-type=\"string\"", paragraphsXML(s))
        case .richText(let runs): return (" office:value-type=\"string\"", paragraphsXML(runs.map(\.text).joined()))
        case .integer(let i): return (" office:value-type=\"\(percent ? "percentage" : "float")\" office:value=\"\(i)\"", ["<text:p>\(i)</text:p>"])
        case .number(let d): return (" office:value-type=\"\(percent ? "percentage" : "float")\" office:value=\"\(d)\"", ["<text:p>\(d)</text:p>"])
        case .bool(let b): return (" office:value-type=\"boolean\" office:boolean-value=\"\(b)\"", ["<text:p>\(b ? "TRUE" : "FALSE")</text:p>"])
        case .date(let dt):
            let iso = dt.isMidnight ? dt.date.description : dt.iso8601
            return (" office:value-type=\"date\" office:date-value=\"\(iso)\"", ["<text:p>\(iso)</text:p>"])
        case .time(let t):
            return (" office:value-type=\"time\" office:time-value=\"\(isoDuration(hours: t.hour, minutes: t.minute, seconds: Double(t.second) + Double(t.nanosecond) / 1e9))\"", ["<text:p>\(t.description)</text:p>"])
        case .duration(let d):
            let (secs, attos) = d.components
            let total = Double(secs) + Double(attos) / 1e18
            let negative = total < 0
            let abs = Swift.abs(total)
            let h = Int(abs / 3600), m = Int(abs) / 60 % 60, sec = abs - Double(h * 3600 + m * 60)
            let iso = (negative ? "-" : "") + isoDuration(hours: h, minutes: m, seconds: sec)
            return (" office:value-type=\"time\" office:time-value=\"\(iso)\"", ["<text:p>\(XML.esc(v.pythonString))</text:p>"])
        case .error(let e): return (" office:value-type=\"string\"", ["<text:p>\(XML.esc(e))</text:p>"])
        case .formula(_, let cached): return cached.map { valueXML($0, percent: percent) } ?? ("", [])
        }
    }

    static func isoDuration(hours: Int, minutes: Int, seconds: Double) -> String {
        let whole = seconds.rounded(.down)
        let secText = seconds == whole ? String(format: "%02d", Int(whole)) : String(format: "%09.6f", seconds)
        return String(format: "PT%02dH%02dM", hours, minutes) + secText + "S"
    }

    /// `<text:p>` elements for a string: one per line, with ODF's white-space rules (leading / trailing / repeated
    /// spaces as `text:s`, tabs as `text:tab`).
    static func paragraphsXML(_ text: String) -> [String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { line in
            var out = "<text:p>"
            let chars = Array(line)
            var i = 0
            while i < chars.count {
                let ch = chars[i]
                if ch == " " {
                    var n = 1
                    while i + n < chars.count, chars[i + n] == " " { n += 1 }
                    let leading = i == 0, trailing = i + n == chars.count
                    if leading || trailing { out += "<text:s\(n > 1 ? " text:c=\"\(n)\"" : "")/>" }
                    else { out += " " + (n > 1 ? "<text:s\(n > 2 ? " text:c=\"\(n - 1)\"" : "")/>" : "") }
                    i += n
                } else if ch == "\t" {
                    out += "<text:tab/>"; i += 1
                } else {
                    var n = 1
                    while i + n < chars.count, chars[i + n] != " ", chars[i + n] != "\t" { n += 1 }
                    out += XML.esc(String(chars[i..<(i + n)]).replacingOccurrences(of: "\r", with: "")); i += n
                }
            }
            return out + "</text:p>"
        }
    }
}
