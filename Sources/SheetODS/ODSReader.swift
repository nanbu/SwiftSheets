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
        let zip = try ZipArchive(data: data, limits: options.limits)
        // An encrypted ODF package keeps `mimetype` in the clear, so it detects as .ods and every part after it is
        // ciphertext. The manifest says as much (ODF 1.3 §4.3) — read that before trying to parse the ciphertext.
        if let unopenable = UnopenableInput.probe(in: try ZipInspection(data: data)) { throw unopenable.error }
        guard zip.contains("content.xml") else { throw SheetError.malformedPart(path: "content.xml", detail: "content.xml missing from the package") }

        let manifest = ManifestParser()
        if zip.contains("META-INF/manifest.xml") { try? manifest.run(try zip.read("META-INF/manifest.xml"), part: "META-INF/manifest.xml") }

        let catalog = ODSStyleCatalog()
        if zip.contains("styles.xml") { try StylesPartParser(catalog: catalog).run(try zip.read("styles.xml"), part: "styles.xml") }

        let content = ContentParser(catalog: catalog, dataOnly: options.dataOnly, cellLimit: options.cellLimit)
        try content.run(stream: try zip.stream("content.xml"), part: "content.xml")   // a piece at a time
        guard !content.sheets.isEmpty else { throw SheetError.invalidWorkbook("the spreadsheet has no tables") }

        var sheetsRead = content.sheets
        // print setup: each sheet's table style names the master page it prints with
        for i in sheetsRead.indices where i < content.tableStyleNames.count {
            guard let name = catalog.masterPage(ofTableStyle: content.tableStyleNames[i]),
                  let master = catalog.masterPages[name] else { continue }
            ODSPageStyles.apply(master: master, layout: master.layout.flatMap { catalog.pageLayouts[$0] }, to: &sheetsRead[i])
        }
        // data pilots become the pivot tables of the sheet they are drawn on
        for parsed in content.dataPilots {
            guard let target = parsed.target?.sheet, let i = sheetsRead.firstIndex(where: { $0.name == target }),
                  let pivot = ODSPivot.pivotTable(parsed) else { continue }
            sheetsRead[i].pivotTables.append(pivot)
        }
        // database ranges: a named one is an Excel table, the anonymous one is the sheet's auto-filter
        for entry in content.databaseRanges {
            guard let target = entry.range.sheet, let i = sheetsRead.firstIndex(where: { $0.name == target }) else { continue }
            var range = entry.range; range.sheet = nil
            if entry.name.hasPrefix("__Anonymous_Sheet_DB__") {
                sheetsRead[i].autoFilter = range
                sheetsRead[i].filterColumns = entry.filters
                if !entry.sort.isEmpty { sheetsRead[i].sortState = SortState(range: range, conditions: entry.sort) }
            } else {
                let header = (range.topLeft.col...range.bottomRight.col).map { sheetsRead[i][range.topLeft.row, $0] }
                var table = ExcelTable(name: entry.name, ref: range, headerRow: header, styleInfo: nil)
                if !entry.buttons { table.autoFilter = nil }
                sheetsRead[i].excelTables.append(table)
            }
        }

        var wb = Workbook(sheets: sheetsRead)
        wb.calculationSettings = content.calculationSettings
        if let e = content.epoch { wb.epoch = e }
        wb.labelRanges = content.labelRanges
        wb.consolidation = content.consolidation
        wb.noteUnmodelledODFFeatures(content.unmodelledODF)
        wb.dataOnly = options.dataOnly
        wb.definedNames = content.definedNames
        wb.preserved.sourceFormat = .ods
        var source = SourceInfo(format: .ods)

        if zip.contains("meta.xml") {
            let meta = MetaParser()
            try? meta.run(try zip.read("meta.xml"), part: "meta.xml")
            wb.metadata = meta.properties
            wb.customProperties = meta.customProperties
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
                let (payload, entry) = try zip.compressed(name)
                wb.preserved.parts[name] = .compressed(payload: payload, method: entry.method, crc32: entry.crc32, uncompressedSize: entry.uncompressedSize)
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
    static let sections: Set<String> = ["font-face-decls", "styles", "automatic-styles", "master-styles"]
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
    private var rowMatrices: [(col: Int, cols: Int, rows: Int)] = []
    private var rowHasValidation = false
    private var cellCursor = 0

    // cell state
    private var inCell = false
    private var cellAttrs: [String: String] = [:]
    private var cellCovered = false
    private var paragraphs: [String] = []
    /// The runs of a paragraph, when it carries `text:span` children — ODF's way of formatting part of a cell.
    private var runs: [(text: String, style: String?)] = []
    private var spanStyle: String?
    private var spanDepth = 0
    private var runStart = 0
    private var paragraph = ""
    private var inParagraph = false
    private var lastWasCollapsibleSpace = true
    private var hyperlink: Hyperlink?
    private var inAnnotation = false
    private var annotationSeen = false
    private var noteParagraphs: [String] = []
    private var noteAuthor = ""
    private var inCreator = false

    // conditional formats (calcext)
    private var cfRanges = MultiCellRange()
    private var cfRules: [ConditionalFormattingRule] = []
    private var cfPriority = 0
    private var cfValues: [ConditionalValue] = []
    private var cfColors: [Color] = []
    private var cfBar: [String: String] = [:]
    private var cfIcon: String?

    // content validations
    var validations: [String: ODSValidation.Parsed] = [:]
    private var currentValidation: ODSValidation.Parsed?
    private var validationMessage: String?
    private var validationMessageText: [String] = []
    /// validation name → the cells that named it, as row runs
    private var validationCells: [String: [(row: Int, from: Int, to: Int)]] = [:]
    private var rowValidations: [(name: String, from: Int, to: Int)] = []

    // database ranges: filters and sort, held until the sheets are known
    private var dbName: String?
    private var dbRange: CellRange?
    private var dbButtons = false
    private var dbFilters: [FilterColumn] = []
    private var dbSort: [SortCondition] = []
    private var dbInFilter = false
    private var dbOr = false
    var databaseRanges: [(name: String, range: CellRange, buttons: Bool, filters: [FilterColumn], sort: [SortCondition])] = []

    private var filterSetTarget: Int?
    private var inValidationParagraph = false
    /// Cells naming a style that carries `style:map` — ODF 1.3's own conditional format, which producers older
    /// than LibreOffice's `calcext:` extension are the only ones to write.
    private var styleMapCells: [String: [(row: Int, from: Int, to: Int)]] = [:]
    private var styleMapColumns: [(style: String, from: Int, to: Int)] = []
    private var rowStyleMaps: [(style: String, from: Int, to: Int)] = []
    private var rowHasStyleMap = false
    /// A `calcext:` rule the model has no word for; the sheet says so with `hasUnmodelledConditionalFormats`.
    private var unreadableConditionalFormat = false
    /// True once this sheet has produced a `calcext:` block. LibreOffice writes both forms, and the `style:map`
    /// copy of the same rules would double every one of them.
    private var sheetHasCalcextFormats = false

    // data pilots, held until the sheets are known
    private var pilot: ODSPivot.Parsed?
    private var pilotField: (name: String, orientation: String, function: String, displayName: String?)?
    var dataPilots: [ODSPivot.Parsed] = []

    // ODF's own features (spec Appendix B.17)
    var calculationSettings = CalculationSettings()
    var epoch: DateEpoch?
    var labelRanges: [LabelRange] = []
    var consolidation: Consolidation?
    var unmodelledODF: UnmodelledODFFeatures = []
    private var detective: CellDetective?
    private var reportedExtraLink = false
    private var rowDetective: [(col: Int, detective: CellDetective)] = []

    // the table style of the sheet being read, so its master page can be applied afterwards
    var tableStyleNames: [String] = []

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
            let styleName = ODSAttr.get(a, "table:style-name")
            if catalog.isTableHidden(styleName) { s.state = .hidden }
            tableStyleNames.append(styleName ?? "")
            if ODSAttr.bool(a, "table:protected") == true { s.protection.enabled = true }
            if let ranges = ODSAttr.get(a, "table:print-ranges") {
                s.printArea = ranges.split(separator: " ").compactMap { CellRange(ContentParser.excelAddress(String($0))) }
                    .map { var r = $0; r.sheet = nil; return r }
            }
            sheet = s
            columnCursor = 0; rowCursor = 0; groupDepth = 0; columnDefaults = []
            cfRules = []; cfRanges = MultiCellRange(); cfPriority = 0
            validationCells = [:]; styleMapCells = [:]; styleMapColumns = []; sheetHasCalcextFormats = false
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
            if catalog.hasBreakBefore(styleName, row: false), n < ODSReader.paddingRepeat, columnCursor < ODSReader.maxColumns {
                sheet?.columnBreaks.append(columnCursor)
            }
            if let d = defaultCell, !catalog.conditionalMaps(d).isEmpty, n < ODSReader.paddingRepeat, columnCursor < ODSReader.maxColumns {
                styleMapColumns.append((d, columnCursor, Swift.min(columnCursor + n, ODSReader.maxColumns) - 1))
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
            rowCells = []; rowMerges = []; rowMatrices = []; rowHasContent = false; cellCursor = 0
            rowValidations = []; rowHasValidation = false; rowStyleMaps = []; rowHasStyleMap = false; rowDetective = []
            if catalog.hasBreakBefore(rowStyle, row: true), rowCursor < ODSReader.maxRows { sheet?.rowBreaks.append(rowCursor) }
        case "table-cell", "covered-table-cell":
            guard inRow else { return }
            inCell = true
            cellAttrs = a
            cellCovered = name == "covered-table-cell"
            paragraphs = []; runs = []; spanStyle = nil; spanDepth = 0; runStart = 0
            paragraph = ""; inParagraph = false; hyperlink = nil
            inAnnotation = false; annotationSeen = false; noteParagraphs = []; noteAuthor = ""
        case "p":
            if validationMessage != nil { inValidationParagraph = true; paragraph = ""; return }
            guard inCell else { return }
            inParagraph = true; paragraph = ""; lastWasCollapsibleSpace = true
            if !runs.isEmpty { runs.append(("\n", nil)) }
            runStart = runs.count
        case "span":
            guard inParagraph, !inAnnotation else { return }
            spanDepth += 1
            if spanDepth == 1 {
                if !paragraph.isEmpty { runs.append((paragraph, nil)); paragraph = "" }
                spanStyle = ODSAttr.get(a, "text:style-name")
            }
        case "s":
            guard inParagraph else { return }
            appendLiteral(String(repeating: " ", count: Swift.max(1, ODSAttr.int(a, "text:c") ?? 1)))
        case "tab": if inParagraph { appendLiteral("\t") }
        case "line-break": if inParagraph { appendLiteral("\n") }
        case "a":
            guard inParagraph, !inAnnotation, let href = ODSAttr.get(a, "xlink:href") else { return }
            guard hyperlink == nil else {
                // ODF hangs a link on a run of text, so a cell may hold several; the model has one, as Excel does
                if !reportedExtraLink {
                    reportedExtraLink = true
                    warnings.append(ConversionWarning(.degraded, subject: .other, sheet: sheet?.name,
                                                      message: "a cell holds more than one hyperlink; the first was kept"))
                }
                return
            }
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
            // ODF marks the printed rows / columns and the print range on the name itself
            let usable = (ODSAttr.get(a, "table:range-usable-as") ?? "").split(separator: " ").map(String.init)
            if !usable.isEmpty, usable != ["none"], inTable {
                let excel = ContentParser.excelAddress(addr)
                let cells = CellRange.splitSheetName(excel)?.cells ?? excel
                if usable.contains("print-range"), var r = CellRange(cells) { r.sheet = nil; sheet?.printArea.append(r) }
                if let b = RangeBounds(cells) {
                    if usable.contains("repeat-row"), let lo = b.minRow, let hi = b.maxRow { sheet?.printTitleRows = lo...hi }
                    if usable.contains("repeat-column"), let lo = b.minCol, let hi = b.maxCol { sheet?.printTitleColumns = lo...hi }
                }
                return
            }
            addName(n, ContentParser.excelAddress(addr))
        case "named-expression":
            guard let n = ODSAttr.get(a, "table:name"), let expr = ODSAttr.get(a, "table:expression") else { return }
            let parsed = FormulaExpr.parse(expr, dialect: .ods)
            addName(n, parsed.isUnparsed ? expr : parsed.rendered(as: .xlsx))
        case "calculation-settings":
            if let v = ODSAttr.bool(a, "table:case-sensitive") { calculationSettings.caseSensitive = v }
            if let v = ODSAttr.bool(a, "table:precision-as-shown") { calculationSettings.precisionAsShown = v }
            if let v = ODSAttr.bool(a, "table:search-criteria-must-apply-to-whole-cell") { calculationSettings.searchCriteriaMustApplyToWholeCell = v }
            if let v = ODSAttr.bool(a, "table:automatic-find-labels") { calculationSettings.automaticFindLabels = v }
            if let v = ODSAttr.bool(a, "table:use-regular-expressions") { calculationSettings.useRegularExpressions = v }
            if let v = ODSAttr.bool(a, "table:use-wildcards") { calculationSettings.useWildcards = v }
            if let v = ODSAttr.int(a, "table:null-year") { calculationSettings.nullYear = v }
        case "null-date":
            // ODF lets the date origin be any date; the model, like Excel, knows two
            let value = ODSAttr.get(a, "table:date-value") ?? "1899-12-30"
            switch value {
            case "1904-01-01": epoch = .mac1904
            case "1899-12-30", "1900-01-01": epoch = .windows1900
            default:
                epoch = .windows1900
                warnings.append(ConversionWarning(.degraded, message: "the date origin \(value) is neither 1899-12-30 nor 1904-01-01; read as the 1900 system, so dates may be out"))
            }
        case "iteration":
            calculationSettings.iterationEnabled = ODSAttr.get(a, "table:status") == "enable"
            if let v = ODSAttr.int(a, "table:steps") { calculationSettings.iterationSteps = v }
            if let v = ODSAttr.get(a, "table:maximum-difference").flatMap(Double.init) { calculationSettings.iterationMaximumDifference = v }
        case "label-range":
            guard let labels = ODSAttr.get(a, "table:label-cell-range-address").flatMap(ODSFeatures.range),
                  let data = ODSAttr.get(a, "table:data-cell-range-address").flatMap(ODSFeatures.range) else { return }
            let orientation = LabelRange.Orientation(rawValue: ODSAttr.get(a, "table:orientation") ?? "column") ?? .column
            labelRanges.append(LabelRange(labels: labels, data: data, orientation: orientation))
        case "consolidation":
            let sources = (ODSAttr.get(a, "table:source-cell-range-addresses") ?? "")
                .split(separator: " ").compactMap { ODSFeatures.range(String($0)) }
            guard !sources.isEmpty,
                  let targetText = ODSAttr.get(a, "table:target-cell-address"),
                  let target = CellRange(ContentParser.excelAddress(targetText)), let targetSheet = target.sheet else { return }
            var c = Consolidation(function: ODSPivot.excelFunction(ODSAttr.get(a, "table:function") ?? "sum"),
                                  sources: sources, target: target.topLeft, targetSheet: targetSheet)
            c.useLabels = Consolidation.Labels(rawValue: ODSAttr.get(a, "table:use-labels") ?? "none") ?? .none
            c.linkToSourceData = ODSAttr.bool(a, "table:link-to-source-data") ?? false
            consolidation = c
        case "detective":
            guard inCell else { return }
            detective = CellDetective()
        case "highlighted-range":
            guard detective != nil, let direction = ODSAttr.get(a, "table:direction").flatMap(CellDetective.HighlightedRange.Direction.init) else { return }
            detective!.highlighted.append(CellDetective.HighlightedRange(
                range: ODSAttr.get(a, "table:cell-range-address").flatMap(ODSFeatures.range),
                direction: direction, containsError: ODSAttr.bool(a, "table:contains-error") ?? false))
        case "operation":
            guard detective != nil, let name = ODSAttr.get(a, "table:name").flatMap(CellDetective.Operation.Name.init) else { return }
            detective!.operations.append(CellDetective.Operation(name, index: ODSAttr.int(a, "table:index") ?? 0))
        case "table-source":
            unmodelledODF.insert(.linkedSheet)
        case "cell-range-source":
            unmodelledODF.insert(.linkedRange)
        case "content-validation":
            guard let n = ODSAttr.get(a, "table:name") else { return }
            currentValidation = ODSValidation.Parsed(name: n, condition: ODSAttr.get(a, "table:condition") ?? "",
                                                    allowEmpty: ODSAttr.bool(a, "table:allow-empty-cell") ?? true,
                                                    displayList: ODSAttr.get(a, "table:display-list"),
                                                    baseAddress: ODSAttr.get(a, "table:base-cell-address"))
        case "help-message", "error-message":
            guard currentValidation != nil else { return }
            validationMessage = name; validationMessageText = []
            if name == "help-message" {
                currentValidation!.helpTitle = ODSAttr.get(a, "table:title")
                currentValidation!.showHelp = ODSAttr.bool(a, "table:display") ?? true
            } else {
                currentValidation!.errorTitle = ODSAttr.get(a, "table:title")
                currentValidation!.errorType = ODSAttr.get(a, "table:message-type")
                currentValidation!.showError = ODSAttr.bool(a, "table:display") ?? true
            }
        case "conditional-format":
            cfRanges = MultiCellRange()
            for part in (a["calcext:target-range-address"] ?? "").split(separator: " ") {
                guard var r = CellRange(ContentParser.excelAddress(String(part))) else { continue }
                r.sheet = nil
                cfRanges.add(r)
            }
            cfValues = []; cfColors = []; cfBar = [:]; cfIcon = nil
        case "condition":
            guard let value = a["calcext:value"] else { return }
            cfPriority += 1
            let style = catalog.differentialStyle(named: a["calcext:apply-style-name"])
            sheetHasCalcextFormats = true
            // spelled out rather than chained: one expression here is more than some toolchains will type-check
            var anchor = cfRanges.sorted.first?.topLeft.a1 ?? "A1"
            if let address = a["calcext:base-cell-address"],
               let cell = ContentParser.internalTarget(address).split(separator: "!").last {
                anchor = String(cell)
            }
            if let rule = ODSCondition.rule(from: value, style: style, priority: cfPriority, anchor: anchor) { cfRules.append(rule) }
            else { unreadableConditionalFormat = true }
        case "date-is":
            sheetHasCalcextFormats = true
            guard let period = a["calcext:date"].flatMap(ODSCondition.timePeriod) else { unreadableConditionalFormat = true; return }
            cfPriority += 1
            var rule = ConditionalFormattingRule(kind: .timePeriod, priority: cfPriority,
                                                 style: catalog.differentialStyle(named: a["calcext:style"]))
            rule.timePeriod = period
            cfRules.append(rule)
        case "color-scale", "data-bar", "icon-set":
            sheetHasCalcextFormats = true
            cfValues = []; cfColors = []
            if name == "data-bar" { cfBar = a }
            if name == "icon-set" { cfIcon = a["calcext:icon-set-type"] }
        case "color-scale-entry", "formatting-entry":
            let kind = ODSCondition.valueKind(a["calcext:type"] ?? "number")
            cfValues.append(ConditionalValue(kind, kind == .min || kind == .max ? nil : a["calcext:value"]))
            if let c = a["calcext:color"] { cfColors.append(Color(hex: c)) }
        case "database-range":
            dbName = ODSAttr.get(a, "table:name")
            dbButtons = ODSAttr.get(a, "table:display-filter-buttons") == "true"
            dbRange = ODSAttr.get(a, "table:target-range-address").flatMap { CellRange(ContentParser.excelAddress($0)) }
            dbFilters = []; dbSort = []; dbInFilter = false; dbOr = false
        case "filter": dbInFilter = true
        case "filter-or": if dbInFilter { dbOr = true }
        case "filter-condition":
            guard dbInFilter, let field = ODSAttr.int(a, "table:field-number") else { return }
            let op = ODSAttr.get(a, "table:operator") ?? "="
            let value = ODSAttr.get(a, "table:value") ?? ""
            if let i = dbFilters.firstIndex(where: { $0.column == field }) {
                dbFilters[i].conditions.append(FilterCondition(ContentParser.comparison(op), value))
                dbFilters[i].matchesAllConditions = !dbOr
            } else {
                var column = FilterColumn(column: field)
                if let c = ContentParser.top10(op, value) { column.top10 = c }
                else { column.conditions = [FilterCondition(ContentParser.comparison(op), value)] }
                dbFilters.append(column)
            }
            filterSetTarget = field
        case "filter-set-item":
            guard let field = filterSetTarget, let i = dbFilters.firstIndex(where: { $0.column == field }) else { return }
            let v = ODSAttr.get(a, "table:value") ?? ""
            dbFilters[i].conditions = []
            dbFilters[i].matchesAllConditions = false
            if v.isEmpty { dbFilters[i].includesBlanks = true } else { dbFilters[i].values.append(v) }
        case "sort-by":
            guard let field = ODSAttr.int(a, "table:field-number"), let range = dbRange else { return }
            let col = range.minCol + field
            dbSort.append(SortCondition(range: CellRange(minRow: range.minRow, minCol: col, maxRow: range.maxRow, maxCol: col),
                                        descending: ODSAttr.get(a, "table:order") == "descending"))
        case "data-pilot-table":
            var p = ODSPivot.Parsed()
            p.name = ODSAttr.get(a, "table:name") ?? ""
            p.target = ODSAttr.get(a, "table:target-range-address").flatMap { CellRange(ContentParser.excelAddress($0)) }
            pilot = p
        case "source-cell-range":
            pilot?.source = ODSAttr.get(a, "table:cell-range-address").flatMap { CellRange(ContentParser.excelAddress($0)) }
        case "data-pilot-field":
            guard pilot != nil, let n = ODSAttr.get(a, "table:source-field-name") else { return }
            pilotField = (n, ODSAttr.get(a, "table:orientation") ?? "hidden", ODSAttr.get(a, "table:function") ?? "auto",
                          ODSAttr.get(a, "tableooo:display-name"))
        case "source-service", "source-table", "data-pilot-groups":
            skipDepth = 1                                    // sources the model has no word for
        case "tracked-changes":
            unmodelledODF.insert(.trackedChanges); skipDepth = 1
        case "dde-links":
            unmodelledODF.insert(.ddeLinks); skipDepth = 1
        case "frame", "shapes", "forms", "custom-shape", "control", "g":
            skipDepth = 1
        case _ where ContentParser.transparent.contains(name):
            if name == "table-row-group" { groupDepth += 1 }
        default: break
        }
    }

    func text(_ s: String) {
        if sectionDepth > 1 { catalog.text(s); return }
        guard skipDepth == 0 else { return }
        if validationMessage != nil, inValidationParagraph { paragraph += s; return }
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
            if validationMessage != nil, inValidationParagraph { inValidationParagraph = false; validationMessageText.append(paragraph); return }
            guard inParagraph else { return }
            inParagraph = false
            if inAnnotation { noteParagraphs.append(paragraph); return }
            if !runs.isEmpty {
                if !paragraph.isEmpty { runs.append((paragraph, nil)) }
                paragraphs.append(runs[runStart...].reduce("") { $0 + $1.text })
                paragraph = ""
                return
            }
            paragraphs.append(paragraph)
        case "help-message", "error-message":
            guard currentValidation != nil, validationMessage == name else { return }
            let text = validationMessageText.joined(separator: "\n")
            if name == "help-message" { currentValidation!.help = text.isEmpty ? nil : text }
            else { currentValidation!.error = text.isEmpty ? nil : text }
            validationMessage = nil
        case "content-validation":
            if let v = currentValidation { validations[v.name] = v }
            currentValidation = nil
        case "conditional-format":
            defer { cfValues = []; cfColors = []; cfBar = [:]; cfIcon = nil }
            if let icon = cfIcon {
                cfPriority += 1
                cfRules.append(.iconSet(IconSet(name: icon, values: cfValues, percent: cfValues.allSatisfy { $0.kind == .percent }), priority: cfPriority))
            } else if !cfBar.isEmpty, cfValues.count >= 2 {
                cfPriority += 1
                let colour = cfBar["calcext:positive-color"].map { Color(hex: $0) } ?? Color(hex: "638EC6")
                cfRules.append(.dataBar(DataBar(color: colour, minimum: cfValues[0], maximum: cfValues[1],
                                                minLength: cfBar["calcext:min-length"].flatMap { Int($0) },
                                                maxLength: cfBar["calcext:max-length"].flatMap { Int($0) }), priority: cfPriority))
            } else if !cfColors.isEmpty, cfColors.count == cfValues.count {
                cfPriority += 1
                cfRules.append(.colorScale(ColorScale(values: cfValues, colors: cfColors), priority: cfPriority))
            }
            guard !cfRules.isEmpty, !cfRanges.isEmpty else { cfRules = []; return }
            sheet?.conditionalFormatting.append(ConditionalFormatting(ranges: cfRanges, rules: cfRules))
            cfRules = []
        case "data-pilot-field":
            if let f = pilotField { pilot?.fields.append(f) }
            pilotField = nil
        case "data-pilot-table":
            if let p = pilot { dataPilots.append(p) }
            pilot = nil
        case "filter": dbInFilter = false
        case "filter-or": dbOr = false
        case "filter-condition": filterSetTarget = nil
        case "database-range":
            if let name = dbName, let range = dbRange {
                databaseRanges.append((name, range, dbButtons, dbFilters, dbSort))
            }
            dbName = nil; dbRange = nil; dbFilters = []; dbSort = []
        case "span":
            guard inParagraph, spanDepth > 0 else { return }
            spanDepth -= 1
            if spanDepth == 0 {
                runs.append((paragraph, spanStyle)); paragraph = ""; spanStyle = nil
            }
        case "creator": inCreator = false
        case "annotation": inAnnotation = false
        case "detective": break
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
            // the rules are declared once for the document; the cells that named them are this sheet's
            for (name, runs) in validationCells.sorted(by: { $0.key < $1.key }) {
                guard let parsed = validations[name] else { continue }
                sheet?.dataValidations.append(ODSValidation.validation(parsed, ranges: ContentParser.ranges(of: runs)))
            }
            validationCells = [:]
            readStyleMaps()
            if unreadableConditionalFormat { sheet?.hasUnmodelledConditionalFormats = true }
            unreadableConditionalFormat = false
            if let s = sheet { sheets.append(s) }
            sheet = nil
        case "table-row-group": groupDepth = Swift.max(0, groupDepth - 1)
        default: break
        }
    }

    /// ODF 1.3's own conditional formats: a `style:map` on the cell style, which only a producer with no
    /// `calcext:` support writes on its own. Read once the sheet's rows are in, and only when the sheet carried no
    /// `calcext:` block — LibreOffice writes both forms of the same rules.
    private func readStyleMaps() {
        defer { styleMapCells = [:]; styleMapColumns = [] }
        guard !sheetHasCalcextFormats, !styleMapCells.isEmpty || !styleMapColumns.isEmpty else { return }
        let lastRow = sheet?.table.extent?.maxRow ?? 0
        var byStyle: [String: MultiCellRange] = [:]
        for (name, runs) in styleMapCells { byStyle[name] = ContentParser.ranges(of: runs) }
        for column in styleMapColumns {
            var ranges = byStyle[column.style] ?? MultiCellRange()
            ranges.add(CellRange(minRow: 0, minCol: column.from, maxRow: lastRow, maxCol: column.to))
            byStyle[column.style] = ranges
        }
        var priority = 0
        for name in byStyle.keys.sorted() {
            guard let ranges = byStyle[name], !ranges.isEmpty else { continue }
            let anchor = ranges.sorted.first?.topLeft.a1 ?? "A1"
            var rules: [ConditionalFormattingRule] = []
            for map in catalog.conditionalMaps(name) {
                priority += 1
                let base = map.base.map { ContentParser.internalTarget($0) }.flatMap { $0.split(separator: "!").last.map(String.init) } ?? anchor
                if let rule = ODSCondition.rule(from: map.condition, style: map.style, priority: priority, anchor: base) { rules.append(rule) }
                else { unreadableConditionalFormat = true }
            }
            if !rules.isEmpty { sheet?.conditionalFormatting.append(ConditionalFormatting(ranges: ranges, rules: rules)) }
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
        var value = decodeValue(a)
        if case .text? = value, runs.contains(where: { $0.style != nil }) {
            let textRuns = runs.map { run -> TextRun in
                guard let name = run.style else { return TextRun(run.text) }
                let style = catalog.cellStyle(named: name)
                return TextRun(run.text, font: style.font)
            }
            value = .richText(textRuns)
        }
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
        // an array formula: ODF puts the span on the cell that holds it
        let matrixCols = intAttr(a, "table:number-matrix-columns-spanned") ?? 0
        let matrixRows = intAttr(a, "table:number-matrix-rows-spanned") ?? 0
        if matrixCols > 0, matrixRows > 0 { rowMatrices.append((cellCursor, matrixCols, matrixRows)) }
        if let rule = attr(a, "table:content-validation-name") {
            rowValidations.append((rule, cellCursor, Swift.min(cellCursor + n, ODSReader.maxColumns) - 1))
            rowHasValidation = true
        }
        if let d = detective, !d.isEmpty { rowDetective.append((cellCursor, d)) }
        detective = nil
        if let styleName, styleName != "Default", !catalog.conditionalMaps(styleName).isEmpty {
            rowStyleMaps.append((styleName, cellCursor, Swift.min(cellCursor + n, ODSReader.maxColumns) - 1))
            rowHasStyleMap = true
        }

        let material = cell.value != nil || cell.hyperlink != nil || cell.comment != nil || matrixCols > 0
            || rowDetective.contains { $0.col == cellCursor }
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

    /// Row runs of cells that named the same validation, merged into as few rectangles as possible.
    static func ranges(of runs: [(row: Int, from: Int, to: Int)]) -> MultiCellRange {
        var out = MultiCellRange()
        var open: [(from: Int, to: Int, first: Int, last: Int)] = []
        for row in Set(runs.map(\.row)).sorted() {
            let spans = runs.filter { $0.row == row }.map { (from: $0.from, to: $0.to) }.sorted { $0.from < $1.from }
            var next: [(from: Int, to: Int, first: Int, last: Int)] = []
            for span in spans {
                if let i = open.firstIndex(where: { $0.from == span.from && $0.to == span.to && $0.last == row - 1 }) {
                    var carried = open.remove(at: i); carried.last = row; next.append(carried)
                } else {
                    next.append((span.from, span.to, row, row))
                }
            }
            for done in open { out.add(CellRange(minRow: done.first, minCol: done.from, maxRow: done.last, maxCol: done.to)) }
            open = next
        }
        for done in open { out.add(CellRange(minRow: done.first, minCol: done.from, maxRow: done.last, maxCol: done.to)) }
        return out
    }

    /// `table:operator` of a filter condition ⇄ the model's comparison.
    static func comparison(_ op: String) -> FilterCondition.Comparison {
        switch op {
        case "!=", "<>": return .notEqual
        case ">": return .greaterThan
        case ">=": return .greaterThanOrEqual
        case "<": return .lessThan
        case "<=": return .lessThanOrEqual
        default: return .equal
        }
    }

    /// ODF's "top values" / "bottom percent" filter operators.
    static func top10(_ op: String, _ value: String) -> Top10Filter? {
        guard op.hasPrefix("top") || op.hasPrefix("bottom"), let n = Double(value) else { return nil }
        return Top10Filter(count: n, top: op.hasPrefix("top"), percent: op.hasSuffix("percent"))
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
        else if (!rowCells.isEmpty || hasDimension || !rowMerges.isEmpty || rowHasValidation || rowHasStyleMap) && rowRepeat < ODSReader.paddingRepeat { expand = rowRepeat }
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
            for m in rowMatrices {
                s.table.arrayFormulas[CellRef(row: r, col: m.col)] = CellRange(minRow: r, minCol: m.col, maxRow: Swift.min(r + m.rows - 1, CellRef.maxRow), maxCol: Swift.min(m.col + m.cols - 1, CellRef.maxCol))
            }
            for v in rowValidations { validationCells[v.name, default: []].append((r, v.from, v.to)) }
            for m in rowStyleMaps { styleMapCells[m.style, default: []].append((r, m.from, m.to)) }
            for d in rowDetective { s.table.detective[CellRef(row: r, col: d.col)] = d.detective }
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
    var customProperties = CustomDocumentProperties()
    var generator: String?
    private var current: String?
    private var buffer = ""
    private var userDefinedName: String?
    private var userDefinedType: String?
    static let wanted: Set<String> = ["initial-creator", "creator", "title", "description", "subject", "keyword", "creation-date", "date", "generator", "user-defined"]

    func start(_ name: String, _ a: [String: String]) {
        guard MetaParser.wanted.contains(name) else { return }
        current = name; buffer = ""
        if name == "user-defined" {
            userDefinedName = a["meta:name"] ?? a["name"]
            userDefinedType = a["meta:value-type"] ?? a["value-type"]
        }
    }
    func text(_ s: String) { if current != nil { buffer += s } }
    func end(_ name: String) {
        guard let c = current, c == name else { return }
        current = nil
        let v = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if c == "user-defined" {
            defer { userDefinedName = nil; userDefinedType = nil }
            guard let n = userDefinedName, !n.isEmpty else { return }
            switch userDefinedType {
            case "float": customProperties[n] = Double(v).map { $0 == $0.rounded() && abs($0) < 1e15 ? .integer(Int($0)) : .number($0) } ?? .text(v)
            case "boolean": customProperties[n] = .bool(v == "true" || v == "1")
            case "date", "time": customProperties[n] = MetaParser.date(v).map { .date($0) } ?? .text(v)
            default: customProperties[n] = .text(v)
            }
            return
        }
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
