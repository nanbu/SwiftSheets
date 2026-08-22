import Foundation
import SheetCore

/// Reads an ODF package: manifest → styles.xml → content.xml → meta.xml → settings.xml, keeping every other entry as
/// an opaque part (spec §8, Appendix B.8).
enum ODSReader {
    static let interpretedParts: Set<String> = ["mimetype", "content.xml", "styles.xml", "meta.xml", "settings.xml", "META-INF/manifest.xml"]
    /// RLE caps (spec §8.3): a repeat this large with nothing in it is padding, not content.
    static let paddingRepeat = 1000
    /// How many cells one document may expand to. `number-columns-repeated` and `number-rows-repeated` multiply, so
    /// a kilobyte of XML can ask for 16,384 × 1,048,576 cells — seventeen billion, none of which fit in memory. Past
    /// this many the reader stops materialising and says so (`degraded`), the same judgement `paddingRepeat` makes
    /// for empty runs: a repeat that large is a description of a sheet, not its content.
    ///
    /// The default lives on `ReadOptions.cellLimit`; a caller with a genuinely huge sheet (or a tight memory
    /// budget) chooses their own.
    static var maxCells: Int { ReadOptions().cellLimit }
    static let maxColumns = CellRef.maxCol + 1
    static let maxRows = CellRef.maxRow + 1

    static func read(_ data: Data, options: ReadOptions) throws -> (Workbook, [ConversionWarning]) {
        let zip = try ZipArchive(data: data)
        guard zip.contains("content.xml") else { throw SheetError.malformedPart(path: "content.xml", detail: "content.xml missing from the package") }

        let manifest = ManifestParser()
        if zip.contains("META-INF/manifest.xml") { try? manifest.run(try zip.read("META-INF/manifest.xml"), part: "META-INF/manifest.xml") }

        let catalog = ODSStyleCatalog()
        if zip.contains("styles.xml") { try StylesPartParser(catalog: catalog).run(try zip.read("styles.xml"), part: "styles.xml") }

        let content = ContentParser(catalog: catalog, dataOnly: options.dataOnly, cellLimit: options.cellLimit)
        try content.run(try zip.read("content.xml"), part: "content.xml")
        guard !content.sheets.isEmpty else { throw SheetError.invalidWorkbook("the spreadsheet has no tables") }

        var wb = Workbook(sheets: content.sheets)
        wb.dataOnly = options.dataOnly
        wb.definedNames = content.definedNames
        wb.preserved.sourceFormat = .ods
        var source = SourceInfo(format: .ods)

        if zip.contains("meta.xml") {
            let meta = MetaParser()
            try? meta.run(try zip.read("meta.xml"), part: "meta.xml")
            wb.metadata = meta.properties
            source.application = meta.generator
        }
        wb.sourceInfo = source
        wb.preserved.application = source.application

        if zip.contains("settings.xml") {
            let settings = SettingsParser()
            try? settings.run(try zip.read("settings.xml"), part: "settings.xml")
            for i in wb.sheets.indices {
                guard let items = settings.tables[wb.sheets[i].name] else { continue }
                let hMode = Int(items["HorizontalSplitMode"] ?? "0") ?? 0, vMode = Int(items["VerticalSplitMode"] ?? "0") ?? 0
                let cols = hMode == 2 ? Int(items["HorizontalSplitPosition"] ?? "0") ?? 0 : 0
                let rows = vMode == 2 ? Int(items["VerticalSplitPosition"] ?? "0") ?? 0 : 0
                if rows > 0 || cols > 0 { wb.sheets[i].freezePanes = CellRef(row: rows, col: cols) }
            }
            if let active = settings.activeTable, let i = wb.sheets.index(of: active) { wb.activeIndex = i }
        }

        if options.preserveUnknownParts {
            for name in zip.entries.keys where !interpretedParts.contains(name) && !name.hasSuffix("/") && !name.hasPrefix("Thumbnails/") {
                wb.preserved.opaqueParts[name] = try zip.read(name)
                if let mt = manifest.mediaTypes[name] { wb.preserved.contentTypeOverrides[name] = mt }
            }
        }

        var warnings = content.warnings
        for ds in catalog.unmappedDataStyles {
            warnings.append(ConversionWarning(.degraded, message: "data style \(ds) has no Excel number-format equivalent; General used"))
        }
        return (wb, warnings)
    }
}

// MARK: - META-INF/manifest.xml

final class ManifestParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    var mediaTypes: [String: String] = [:]
    func start(_ name: String, _ a: [String: String]) {
        if name == "file-entry", let p = ODSAttr.get(a, "manifest:full-path"), let t = ODSAttr.get(a, "manifest:media-type") { mediaTypes[p] = t }
    }
}

// MARK: - styles.xml

final class StylesPartParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    let catalog: ODSStyleCatalog
    private var depth = 0
    private var sectionDepth = 0
    static let sections: Set<String> = ["font-face-decls", "styles", "automatic-styles"]
    init(catalog: ODSStyleCatalog) { self.catalog = catalog }
    func start(_ name: String, _ a: [String: String]) {
        depth += 1
        if sectionDepth > 0 { sectionDepth += 1; catalog.start(name, a) }
        else if depth == 2, StylesPartParser.sections.contains(name) { sectionDepth = 1 }
    }
    func text(_ s: String) { if sectionDepth > 1 { catalog.text(s) } }
    func end(_ name: String) {
        if sectionDepth > 0 { sectionDepth -= 1; if sectionDepth > 0 { catalog.end(name) } }
        depth -= 1
    }
}

// MARK: - content.xml

final class ContentParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    let catalog: ODSStyleCatalog
    let dataOnly: Bool
    /// How many cells this document may expand to (`ReadOptions.cellLimit`).
    let cellLimit: Int
    var sheets: [Sheet] = []
    var definedNames: [String: String] = [:]
    var warnings: [ConversionWarning] = []

    private var depth = 0
    private var lenient = true         // attribute lookups scan for other prefixes only when the root binds non-standard ones
    private var sectionDepth = 0       // inside font-face-decls / automatic-styles / styles
    private var skipDepth = 0          // inside a subtree we ignore (draw:frame, office:forms, nested tables, …)
    static let sections: Set<String> = ["font-face-decls", "styles", "automatic-styles"]
    static let transparent: Set<String> = ["table-row-group", "table-header-rows", "table-rows", "table-columns", "table-header-columns", "table-column-group"]

    // table state
    private var sheet: Sheet?
    private var inTable = false
    private var columnCursor = 0
    private var rowCursor = 0
    private var groupDepth = 0
    private var columnDefaults: [(start: Int, end: Int, name: String)] = []

    // how much of the document's cell budget has been spent, and whether anything was clipped (spec §8.3)
    private var cellsMaterialised = 0
    private var truncated = false

    // row state
    private var inRow = false
    private var rowRepeat = 1
    private var rowStyle: String?
    private var rowHidden = false
    private var rowCells: [(col: Int, cell: Cell)] = []
    private var rowHasContent = false
    private var rowMerges: [(col: Int, cols: Int, rows: Int)] = []
    private var cellCursor = 0

    // cell state
    private var inCell = false
    private var cellAttrs: [String: String] = [:]
    private var cellCovered = false
    private var paragraphs: [String] = []
    private var paragraph = ""
    private var inParagraph = false
    private var lastWasCollapsibleSpace = true
    private var hyperlink: Hyperlink?
    private var inAnnotation = false
    private var annotationSeen = false
    private var noteParagraphs: [String] = []
    private var noteAuthor = ""
    private var inCreator = false

    init(catalog: ODSStyleCatalog, dataOnly: Bool, cellLimit: Int) {
        self.catalog = catalog
        self.dataOnly = dataOnly
        self.cellLimit = cellLimit
    }

    func start(_ name: String, _ a: [String: String]) {
        depth += 1
        if depth == 1 { lenient = !ODSAttr.usesStandardPrefixes(rootAttributes) }
        if sectionDepth > 0 { sectionDepth += 1; catalog.start(name, a); return }
        if depth == 2, ContentParser.sections.contains(name) { sectionDepth = 1; return }
        if skipDepth > 0 { skipDepth += 1; return }

        switch name {
        case "table":
            if inTable { skipDepth = 1; return }   // a sub-table inside a cell
            inTable = true
            var s = Sheet(name: ODSAttr.get(a, "table:name") ?? "Sheet\(sheets.count + 1)")
            if catalog.isTableHidden(ODSAttr.get(a, "table:style-name")) { s.state = .hidden }
            sheet = s
            columnCursor = 0; rowCursor = 0; groupDepth = 0; columnDefaults = []
        case "table-column":
            guard inTable, !inRow else { return }
            let n = Swift.max(1, ODSAttr.int(a, "table:number-columns-repeated") ?? 1)
            let styleName = ODSAttr.get(a, "table:style-name")
            let width = catalog.columnWidthCharacters(styleName)
            let hidden = ODSAttr.get(a, "table:visibility") == "collapse"
            let defaultCell = ODSAttr.get(a, "table:default-cell-style-name")
            if let d = defaultCell, d != "Default", columnCursor < ODSReader.maxColumns {
                columnDefaults.append((columnCursor, Swift.min(columnCursor + n, ODSReader.maxColumns) - 1, d))
            }
            if n < ODSReader.paddingRepeat, width != nil || hidden || (defaultCell != nil && defaultCell != "Default") {
                let style = defaultCell.flatMap { $0 == "Default" ? nil : catalog.cellStyle(named: $0) }
                for c in columnCursor..<Swift.min(columnCursor + n, ODSReader.maxColumns) {
                    sheet?.columnDimensions[c] = ColumnDimension(width: width, hidden: hidden, style: style == .default ? nil : style)
                }
            }
            columnCursor += n
        case "table-row":
            guard inTable else { return }
            inRow = true
            rowRepeat = Swift.max(1, ODSAttr.int(a, "table:number-rows-repeated") ?? 1)
            rowStyle = ODSAttr.get(a, "table:style-name")
            rowHidden = ODSAttr.get(a, "table:visibility") == "collapse"
            rowCells = []; rowMerges = []; rowHasContent = false; cellCursor = 0
        case "table-cell", "covered-table-cell":
            guard inRow else { return }
            inCell = true
            cellAttrs = a
            cellCovered = name == "covered-table-cell"
            paragraphs = []; paragraph = ""; inParagraph = false; hyperlink = nil
            inAnnotation = false; annotationSeen = false; noteParagraphs = []; noteAuthor = ""
        case "p":
            guard inCell else { return }
            inParagraph = true; paragraph = ""; lastWasCollapsibleSpace = true
        case "s":
            guard inParagraph else { return }
            appendLiteral(String(repeating: " ", count: Swift.max(1, ODSAttr.int(a, "text:c") ?? 1)))
        case "tab": if inParagraph { appendLiteral("\t") }
        case "line-break": if inParagraph { appendLiteral("\n") }
        case "a":
            guard inParagraph, !inAnnotation, hyperlink == nil, let href = ODSAttr.get(a, "xlink:href") else { return }
            if href.hasPrefix("#") {
                let target = String(href.dropFirst())
                hyperlink = Hyperlink(target: ContentParser.internalTarget(target), isInternal: true)
            } else {
                hyperlink = Hyperlink(target: href)
            }
        case "annotation":
            guard inCell else { return }
            inAnnotation = true; annotationSeen = true
        case "creator": if inAnnotation { inCreator = true; noteAuthor = "" }
        case "named-range":
            guard let n = ODSAttr.get(a, "table:name"), let addr = ODSAttr.get(a, "table:cell-range-address") else { return }
            addName(n, ContentParser.excelAddress(addr))
        case "named-expression":
            guard let n = ODSAttr.get(a, "table:name"), let expr = ODSAttr.get(a, "table:expression") else { return }
            let parsed = FormulaExpr.parse(expr, dialect: .ods)
            addName(n, parsed.isUnparsed ? expr : parsed.rendered(as: .xlsx))
        case "database-range":
            // LibreOffice stores an auto-filter as an anonymous database range with filter buttons
            guard ODSAttr.get(a, "table:display-filter-buttons") == "true" || (ODSAttr.get(a, "table:name") ?? "").hasPrefix("__Anonymous_Sheet_DB__"),
                  let address = ODSAttr.get(a, "table:target-range-address"),
                  let range = CellRange(ContentParser.excelAddress(address)), let target = range.sheet else { return }
            if let i = sheets.firstIndex(where: { $0.name == target }) {
                var r = range; r.sheet = nil
                sheets[i].autoFilter = r
            }
        case "frame", "shapes", "forms", "custom-shape", "control", "g", "content-validations", "data-pilot-tables", "calculation-settings", "tracked-changes", "label-ranges", "consolidation", "dde-links", "detective":
            skipDepth = 1
        case _ where ContentParser.transparent.contains(name):
            if name == "table-row-group" { groupDepth += 1 }
        default: break
        }
    }

    func text(_ s: String) {
        if sectionDepth > 1 { catalog.text(s); return }
        guard skipDepth == 0 else { return }
        if inCreator { noteAuthor += s; return }
        guard inParagraph, !s.isEmpty else { return }
        // ODF 6.1.2: character-data white space collapses to one space, and leading white space is ignored
        let scalars = s.unicodeScalars
        if !scalars.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
            paragraph += s; lastWasCollapsibleSpace = false; return
        }
        var out = String.UnicodeScalarView()
        for ch in scalars {
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                if lastWasCollapsibleSpace { continue }
                out.append(" "); lastWasCollapsibleSpace = true
            } else {
                out.append(ch); lastWasCollapsibleSpace = false
            }
        }
        paragraph += String(out)
    }

    private func appendLiteral(_ s: String) { paragraph += s; lastWasCollapsibleSpace = false }

    func end(_ name: String) {
        defer { depth -= 1 }
        if sectionDepth > 0 { sectionDepth -= 1; if sectionDepth > 0 { catalog.end(name) }; return }
        if skipDepth > 0 { skipDepth -= 1; return }
        switch name {
        case "p":
            guard inParagraph else { return }
            inParagraph = false
            if inAnnotation { noteParagraphs.append(paragraph) } else { paragraphs.append(paragraph) }
        case "creator": inCreator = false
        case "annotation": inAnnotation = false
        case "table-cell", "covered-table-cell":
            guard inCell else { return }
            inCell = false
            finishCell()
        case "table-row":
            guard inRow else { return }
            inRow = false
            finishRow()
        case "table":
            guard inTable else { return }
            inTable = false
            // the anchor of a merge has to exist as a cell even when it holds nothing: it is where the span is
            // written, so a merged band with an empty anchor would otherwise disappear on the way back out
            if let s = sheet, !s.table.merges.isEmpty {
                var t = s.table
                for m in t.merges { t.cleanMergedRange(m) }
                sheet?.table = t
            }
            if truncated {
                truncated = false
                warnings.append(ConversionWarning(.degraded, sheet: sheet?.name,
                                                  message: "the repeated rows / cells of this sheet describe more than \(cellLimit) cells; reading stopped there"))
            }
            if let s = sheet { sheets.append(s) }
            sheet = nil
        case "table-row-group": groupDepth = Swift.max(0, groupDepth - 1)
        default: break
        }
    }

    private func addName(_ name: String, _ text: String) {
        if inTable { sheet?.definedNames[name] = text } else { definedNames[name] = text }
    }

    // MARK: - Cells

    private func attr(_ a: [String: String], _ q: String) -> String? { ODSAttr.get(a, q, lenient: lenient) }
    private func intAttr(_ a: [String: String], _ q: String) -> Int? { attr(a, q).flatMap { Int($0) } }

    private func finishCell() {
        let a = cellAttrs
        let n = Swift.max(1, intAttr(a, "table:number-columns-repeated") ?? 1)
        defer { cellCursor += n }
        guard !cellCovered, cellCursor < ODSReader.maxColumns else { return }

        var cell = Cell()
        let styleName = attr(a, "table:style-name")
        if let styleName, styleName != "Default" {
            cell.sharedStyle = catalog.sharedCellStyle(named: styleName)
        } else if let d = columnDefaults.first(where: { $0.start <= cellCursor && cellCursor <= $0.end }) {
            cell.sharedStyle = catalog.sharedCellStyle(named: d.name)
        }
        let value = decodeValue(a)
        if let formula = attr(a, "table:formula"), !dataOnly {
            cell.value = .formula(FormulaExpr.parse(formula, dialect: .ods), cached: value)
        } else {
            cell.value = value
        }
        if let h = hyperlink { cell.hyperlink = h }
        if annotationSeen {
            cell.comment = CellNote(noteParagraphs.joined(separator: "\n"), author: noteAuthor.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let colSpan = intAttr(a, "table:number-columns-spanned") ?? 1
        let rowSpan = intAttr(a, "table:number-rows-spanned") ?? 1
        if colSpan > 1 || rowSpan > 1 { rowMerges.append((cellCursor, colSpan, rowSpan)) }

        let material = cell.value != nil || cell.hyperlink != nil || cell.comment != nil
        guard material || (cell.style != .default && n < ODSReader.paddingRepeat) else { return }
        if material { rowHasContent = true }
        let count = Swift.min(n, ODSReader.maxColumns - cellCursor)
        for i in 0..<count { rowCells.append((cellCursor + i, cell)) }
    }

    private func decodeValue(_ a: [String: String]) -> CellValue? {
        let text = paragraphs.joined(separator: "\n")
        let isErrorText = CellValue.errorCodes.contains(text)
        if a["calcext:value-type"] == "error" { return .error(isErrorText ? text : (text.isEmpty ? "#VALUE!" : text)) }
        switch attr(a, "office:value-type") {
        case "float", "percentage", "currency":
            guard let v = attr(a, "office:value") else { return paragraphs.isEmpty ? nil : .text(text) }
            return ContentParser.number(v) ?? (paragraphs.isEmpty ? nil : .text(text))
        case "boolean":
            let v = ODSAttr.get(a, "office:boolean-value")?.lowercased()
            return .bool(v == "true" || v == "1")
        case "date":
            guard let v = ODSAttr.get(a, "office:date-value") else { return nil }
            return ContentParser.date(v) ?? .text(v)
        case "time":
            guard let v = ODSAttr.get(a, "office:time-value") else { return nil }
            return ContentParser.time(v) ?? .text(v)
        case "string":
            if isErrorText { return .error(text) }
            if let sv = ODSAttr.get(a, "office:string-value") { return .text(sv) }
            return .text(text)
        default:
            // no type: Excel-style producers sometimes omit it for text
            if paragraphs.isEmpty { return nil }
            return isErrorText ? .error(text) : .text(text)
        }
    }

    static func number(_ v: String) -> CellValue? {
        let s = v.trimmingCharacters(in: .whitespaces)
        if !s.contains("."), !s.contains("e"), !s.contains("E"), let i = Int(s) { return .integer(i) }
        guard let d = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return .number(d)
    }

    /// "2026-09-01" / "2026-09-01T13:30:00" / "2026-09-01T13:30:00.123456789".
    static func date(_ v: String) -> CellValue? {
        let s = v.trimmingCharacters(in: .whitespaces)
        if let d = CivilDate(iso: s) { return .date(CivilDateTime(date: d)) }
        var t = s
        if let dot = t.firstIndex(of: "."), t.distance(from: dot, to: t.endIndex) > 4 { t = String(t[..<t.index(dot, offsetBy: 4)]) }   // ≤ 3 fraction digits
        if let dt = CivilDateTime(iso: t) { return .date(dt) }
        return nil
    }

    /// "PT13H30M00S" / "PT26H00M00.5S" / "-PT1H" → `.time` below 24 h, `.duration` otherwise.
    static func time(_ v: String) -> CellValue? {
        var s = v.trimmingCharacters(in: .whitespaces)
        var negative = false
        if s.hasPrefix("-") { negative = true; s.removeFirst() }
        guard s.hasPrefix("P") else { return nil }
        s.removeFirst()
        var inTime = false, number = "", hours = 0, minutes = 0, seconds = 0.0, days = 0
        for ch in s {
            if ch == "T" { inTime = true; continue }
            if ch.isNumber || ch == "." { number.append(ch); continue }
            guard let n = Double(number) else { return nil }
            number = ""
            switch (ch, inTime) {
            case ("D", false): days = Int(n)
            case ("H", true): hours = Int(n)
            case ("M", true): minutes = Int(n)
            case ("S", true): seconds = n
            default: return nil
            }
        }
        guard number.isEmpty else { return nil }
        let total = Double(days * 86400 + hours * 3600 + minutes * 60) + seconds
        if !negative, total < 86400, days == 0, hours < 24 {
            let whole = Int(seconds)
            return .time(TimeOfDay(hour: hours, minute: minutes, second: whole, nanosecond: Int(((seconds - Double(whole)) * 1e9).rounded())))
        }
        let ms = Int64((total * 1000).rounded())
        return .duration(.milliseconds(negative ? -ms : ms))
    }

    /// `$'My Sheet'.$A$1:.$B$2` → `'My Sheet'!$A$1:$B$2` (through the formula parser, with string surgery as fallback).
    static func excelAddress(_ address: String) -> String {
        let parsed = FormulaExpr.parse("[" + address + "]", dialect: .ods)
        if !parsed.isUnparsed { return parsed.rendered(as: .xlsx) }
        return internalTarget(address)
    }

    /// "Sheet.A1" → "Sheet!A1" for link targets and unparsable addresses.
    static func internalTarget(_ t: String) -> String {
        var s = t.hasPrefix("$") ? String(t.dropFirst()) : t
        if s.hasPrefix("'"), let close = s.dropFirst().firstIndex(of: "'") {
            let name = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            s = CellRef.formulaSheetName(name) + (rest.hasPrefix(".") ? "!" + rest.dropFirst() : String(rest))
        } else if let dot = s.firstIndex(of: ".") {
            s = String(s[..<dot]) + "!" + s[s.index(after: dot)...]
        }
        return s.replacingOccurrences(of: ":.", with: ":")
    }

    // MARK: - Rows

    private func finishRow() {
        guard sheet != nil, rowCursor < ODSReader.maxRows else { rowCursor += rowRepeat; return }
        var s = sheet!
        sheet = nil   // keep the table's storage uniquely referenced while it grows (no copy-on-write per row)
        defer { sheet = s }
        let height = catalog.rowHeightPoints(rowStyle)
        let hasDimension = height != nil || rowHidden || groupDepth > 0
        var expand: Int
        if rowHasContent { expand = Swift.min(rowRepeat, ODSReader.maxRows - rowCursor) }
        else if (!rowCells.isEmpty || hasDimension || !rowMerges.isEmpty) && rowRepeat < ODSReader.paddingRepeat { expand = rowRepeat }
        else { expand = 0 }
        // a repeated row of repeated cells multiplies: clip it to what the document may still spend
        if !rowCells.isEmpty, expand > 0 {
            let affordable = (cellLimit - cellsMaterialised) / rowCells.count
            if expand > affordable {
                expand = Swift.max(0, affordable)
                truncated = true
            }
            cellsMaterialised += expand * rowCells.count
        }
        for r in rowCursor..<(rowCursor + expand) {
            for (c, cell) in rowCells { s.table.store(cell, at: CellRef(row: r, col: c)) }
            if hasDimension { s.table.rowDimensions[r] = RowDimension(height: height, hidden: rowHidden, outlineLevel: groupDepth) }
            for m in rowMerges {
                s.table.merges.append(CellRange(minRow: r, minCol: m.col, maxRow: Swift.min(r + m.rows - 1, CellRef.maxRow), maxCol: Swift.min(m.col + m.cols - 1, CellRef.maxCol)))
            }
        }
        if expand > 0 { s.table.nextAppendRow = Swift.max(s.table.nextAppendRow, rowCursor + expand) }
        rowCursor += rowRepeat
    }
}

// MARK: - meta.xml

final class MetaParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    var properties = DocumentProperties()
    var generator: String?
    private var current: String?
    private var buffer = ""
    static let wanted: Set<String> = ["initial-creator", "creator", "title", "description", "subject", "keyword", "creation-date", "date", "generator"]

    func start(_ name: String, _ a: [String: String]) { if MetaParser.wanted.contains(name) { current = name; buffer = "" } }
    func text(_ s: String) { if current != nil { buffer += s } }
    func end(_ name: String) {
        guard let c = current, c == name else { return }
        current = nil
        let v = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        switch c {
        case "initial-creator": properties.creator = v
        case "creator": if properties.creator == DocumentProperties().creator { properties.creator = v }; properties.lastModifiedBy = v
        case "title": properties.title = v
        case "description": properties.description = v
        case "subject": properties.subject = v
        case "keyword": properties.keywords = properties.keywords.map { $0 + ", " + v } ?? v
        case "creation-date": properties.created = MetaParser.date(v)
        case "date": properties.modified = MetaParser.date(v)
        case "generator": generator = v
        default: break
        }
    }

    static func date(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

// MARK: - settings.xml

final class SettingsParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    /// Sheet name → config item name → text.
    var tables: [String: [String: String]] = [:]
    var activeTable: String?
    private var inTables = false
    private var entryName: String?
    private var itemName: String?
    private var buffer = ""

    func start(_ name: String, _ a: [String: String]) {
        switch name {
        case "config-item-map-named": if ODSAttr.get(a, "config:name") == "Tables" { inTables = true }
        case "config-item-map-entry": if inTables { entryName = ODSAttr.get(a, "config:name") }
        case "config-item": itemName = ODSAttr.get(a, "config:name"); buffer = ""
        default: break
        }
    }
    func text(_ s: String) { if itemName != nil { buffer += s } }
    func end(_ name: String) {
        switch name {
        case "config-item":
            if let n = itemName {
                if let e = entryName { tables[e, default: [:]][n] = buffer }
                else if n == "ActiveTable" { activeTable = buffer }
            }
            itemName = nil
        case "config-item-map-entry": if inTables { entryName = nil }
        case "config-item-map-named": inTables = false
        default: break
        }
    }
}
