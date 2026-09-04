import Foundation
#if canImport(FoundationXML)
import FoundationXML   // where Foundation is split, the XML parser lives in its own module
#endif
import SheetCore

/// Resolves an OPC package into a `Workbook`: _rels/.rels → workbook → its rels → sheets / sharedStrings / styles /
/// docProps. Every part that is not interpreted goes to `Workbook.preserved` untouched (spec §6, §7.2).
enum WorkbookReader {
    static let relOfficeDocument = "/officeDocument"
    static let relWorksheet = "/worksheet"
    static let relSharedStrings = "/sharedStrings"
    static let relStyles = "/styles"
    static let relCalcChain = "/calcChain"
    static let relCore = "/core-properties"
    static let relApp = "/extended-properties"
    static let relCustom = "/custom-properties"
    static let relHyperlink = "/hyperlink"
    static let relTable = "/table"
    static let relPivotTable = "/pivotTable"
    static let relPivotCacheDefinition = "/pivotCacheDefinition"
    static let relPivotCacheRecords = "/pivotCacheRecords"
    static let relVBA = "/vbaProject"

    /// The workbook the package describes, together with what the package held that the model could not take
    /// (spec §6): a part whose XML will not parse is reported rather than passed over in silence.
    static func read(_ data: Data, options: ReadOptions) throws -> (workbook: Workbook, warnings: [ConversionWarning]) {
        var warnings: [ConversionWarning] = []
        // A password-protected workbook is an OLE compound file, not a ZIP; say so instead of "corrupted container".
        if let unopenable = UnopenableInput.probe(data) { throw unopenable.error }
        let zip = try ZipArchive(data: data, limits: options.limits)
        var consumed = Set<String>()
        var wb = Workbook(sheets: [])
        wb.dataOnly = options.dataOnly

        // [Content_Types].xml
        let ct = ContentTypesParser()
        if zip.contains("[Content_Types].xml") { try ct.run(try zip.read("[Content_Types].xml"), part: "[Content_Types].xml"); consumed.insert("[Content_Types].xml") }

        // _rels/.rels → the workbook part
        let rootRels = (try? parseRels(zip, "_rels/.rels")) ?? []
        consumed.insert("_rels/.rels")
        let workbookPath = rootRels.first { $0.type.hasSuffix(relOfficeDocument) }.map { resolvePart($0.target, relativeTo: "") } ?? "xl/workbook.xml"
        guard zip.contains(workbookPath) else { throw SheetError.malformedPart(path: workbookPath, detail: "workbook part missing") }
        let isMacroEnabled = (ct.overrides[workbookPath] ?? "").contains("macroEnabled")
        let wbParser = WorkbookXMLParser()
        try wbParser.run(try zip.read(workbookPath), part: workbookPath)
        consumed.insert(workbookPath)
        wb.epoch = wbParser.date1904 ? .mac1904 : .windows1900
        wb.definedNames = wbParser.definedNames
        wb.codeName = wbParser.codeName
        wb.protection = wbParser.protection
        // the calculation settings OOXML shares with ODF (spec Appendix B.40.4): iteration and full precision;
        // the rest of <calcPr> (calcMode, refMode, …) travels for a same-format write
        let calc = wbParser.calcPrAttributes
        wb.preserved.calcPrAttributes = calc
        if XMLBool.isTrue(calc["iterate"]) { wb.calculationSettings.iterationEnabled = true }
        if let n = Int(calc["iterateCount"] ?? "") { wb.calculationSettings.iterationSteps = n }
        if let d = Double(calc["iterateDelta"] ?? "") { wb.calculationSettings.iterationMaximumDifference = d }
        if let full = calc["fullPrecision"] { wb.calculationSettings.precisionAsShown = full == "0" || full.lowercased() == "false" }
        wb.preserved.workbookFragments = wbParser.fragments
        wb.preserved.workbookRootAttributes = wbParser.rootAttributes
        wb.preserved.workbookPrAttributes = wbParser.workbookPrAttributes
        wb.preserved.sourceFormat = isMacroEnabled ? .xlsm : .xlsx

        let base = (workbookPath as NSString).deletingLastPathComponent
        let wbRelsPath = relsPath(of: workbookPath)
        let rels = (try? parseRels(zip, wbRelsPath)) ?? []
        consumed.insert(wbRelsPath)
        func resolve(_ target: String) -> String { resolvePart(target, relativeTo: base) }

        // shared strings and styles
        let sstPath = rels.first { $0.type.hasSuffix(relSharedStrings) }.map { resolve($0.target) } ?? "xl/sharedStrings.xml"
        let stylesPath = rels.first { $0.type.hasSuffix(relStyles) }.map { resolve($0.target) } ?? "xl/styles.xml"
        let sst = SharedStringsParser()
        if zip.contains(sstPath) { try sst.run(stream: try zip.stream(sstPath), part: sstPath); consumed.insert(sstPath) }
        let styles = StylesParser()
        if zip.contains(stylesPath) { try styles.run(try zip.read(stylesPath), part: stylesPath); consumed.insert(stylesPath) }
        styles.resolveNamedStyleLinks()
        wb.indexedColors = styles.indexedColors
        wb.differentialStyles = styles.dxfs
        wb.preserved.styleFragments = styles.fragments
        if zip.contains(stylesPath) {
            wb.preserved.styleTables = styles.styleTables
            if !styles.namedStyles.isEmpty { wb.namedStyles = styles.namedStyles }
        }
        if let calc = rels.first(where: { $0.type.hasSuffix(relCalcChain) }) { consumed.insert(resolve(calc.target)) }   // always dropped (Excel rebuilds it)

        // pivot caches: declared on the workbook, one definition part each (plus a record part it points at).
        // Reading them here means the pivot tables on the sheets below can be handed the cache they name.
        var pivotCaches: [Int: PivotCache] = [:]
        for declared in wbParser.pivotCaches {
            guard let rel = rels.first(where: { $0.id == declared.rId }) else { continue }
            let definition = resolve(rel.target)
            guard let data = try? zip.read(definition) else { continue }
            consumed.insert(definition); consumed.insert(relsPath(of: definition))
            let parser = PivotCacheParser()
            do { try parser.run(data, part: definition) } catch {
                warnings.append(ConversionWarning(.dropped, subject: .objects,
                                                  message: "\(definition) could not be parsed; the pivot cache it describes was skipped"))
                continue
            }
            var cache = parser.cache
            cache.definitionPath = definition
            cache.relationshipId = declared.rId
            cache.cacheId = declared.cacheId
            let definitionDir = (definition as NSString).deletingLastPathComponent
            if let recordsRel = ((try? parseRels(zip, relsPath(of: definition))) ?? [])
                .first(where: { $0.type.hasSuffix(relPivotCacheRecords) }) {
                let records = resolvePart(recordsRel.target, relativeTo: definitionDir)
                cache.recordsPath = records
                cache.recordsXML = try? zip.read(records)
                consumed.insert(records); consumed.insert(relsPath(of: records))
            }
            pivotCaches[declared.cacheId] = cache
        }

        // sheets — each one's parse is independent once the shared strings and the style caches are in place
        // (spec Appendix B.41): the caches are filled up front so that the parsers only ever read them, and the
        // sheets are read side by side when the workbook is worth it, or when the caller says so
        styles.prefill()
        let context = SheetReadContext(zip: zip, sst: sst.strings, styles: styles, epoch: wb.epoch, options: options,
                                       contentTypes: ct.overrides, rels: rels, base: base, pivotCaches: pivotCaches, workbookPath: workbookPath)
        let infos = wbParser.sheets
        let parsedBytes = infos.enumerated().compactMap { index, info -> Int? in   // what the grids to be parsed expand to
            guard let rel = rels.first(where: { $0.id == info.rId }), rel.type.hasSuffix(relWorksheet) else { return nil }
            if let selection = options.sheets, !selection.includes(name: info.name, index: index) { return nil }
            return zip.entries[resolve(rel.target)]?.uncompressedSize ?? 0
        }
        let workers = concurrency(parsedBytes: parsedBytes, options: options)
        let results = SheetResultsBox(count: infos.count)
        if workers > 1 {
            let queue = SheetQueue(count: infos.count)
            DispatchQueue.concurrentPerform(iterations: workers) { _ in
                while let i = queue.take() { results.set(i, context.read(index: i, info: infos[i])) }
            }
        } else {
            for i in infos.indices { results.set(i, context.read(index: i, info: infos[i])) }
        }
        // sheet order, whichever order they finished in: the warnings keep it, and the first failure in it is the
        // one thrown
        var sheets: [Sheet] = []
        for r in results.all {
            if let error = r.error { throw error }
            if let sheet = r.sheet { sheets.append(sheet) }
            consumed.formUnion(r.consumed)
            warnings.append(contentsOf: r.warnings)
        }
        guard !sheets.isEmpty else { throw SheetError.invalidWorkbook("workbook has no sheets") }
        // an unread sheet's cells index the shared strings and the cell formats by position: keep both tables
        // whole so a write-back leaves those positions where they were
        if sheets.contains(where: { $0.preserved.isUnread }) { wb.preserved.sharedStrings = sst.strings }
        wb.sheets = Sheets(sheets)
        // names the file gave that Sheets de-duplicated are an upstream defect; keep the file's order regardless
        wb.activeIndex = Swift.min(wbParser.activeTab, sheets.count - 1)
        assignLocalNames(wbParser.localNames, to: &wb)

        // document properties
        if let core = rootRels.first(where: { $0.type.hasSuffix(relCore) }).map({ resolvePart($0.target, relativeTo: "") }), zip.contains(core) {
            let cp = CorePropertiesParser()
            try? cp.run(try zip.read(core), part: core)
            wb.metadata = cp.props
            consumed.insert(core)
        }
        var source = SourceInfo(format: isMacroEnabled ? .xlsm : .xlsx)
        if let app = rootRels.first(where: { $0.type.hasSuffix(relApp) }).map({ resolvePart($0.target, relativeTo: "") }), zip.contains(app) {
            let ap = AppPropertiesParser()
            try? ap.run(try zip.read(app), part: app)
            source.application = ap.application; source.version = ap.version
            consumed.insert(app)
        }
        if let custom = rootRels.first(where: { $0.type.hasSuffix(relCustom) }).map({ resolvePart($0.target, relativeTo: "") }), zip.contains(custom) {
            let cu = CustomPropertiesParser()
            try? cu.run(try zip.read(custom), part: custom)
            wb.customProperties = cu.properties
            consumed.insert(custom)
        }
        wb.sourceInfo = source
        wb.preserved.application = source.application

        // everything else: kept byte for byte, with the relationships and content types that declare it
        if options.preserveUnknownParts {
            wb.preserved.relationships[workbookPath] = rels.filter { r in
                ![relWorksheet, relSharedStrings, relStyles, relCalcChain, relPivotCacheDefinition].contains { r.type.hasSuffix($0) }
            }
            wb.preserved.relationships["_rels/.rels"] = rootRels.filter { r in ![relOfficeDocument, relCore, relApp, relCustom].contains { r.type.hasSuffix($0) } }
            wb.preserved.contentTypeDefaults = ct.defaults
            for name in zip.entries.keys where !consumed.contains(name) && !name.hasSuffix("/") {
                // kept as the package holds it — folded — so a write-back copies it without expanding it
                let (payload, entry) = try zip.compressed(name)
                wb.preserved.parts[name] = .compressed(payload: payload, method: entry.method, crc32: entry.crc32, uncompressedSize: entry.uncompressedSize)
            }
            wb.preserved.contentTypeOverrides = ct.overrides.filter { wb.preserved.parts[$0.key] != nil }
        }
        return (wb, warnings)
    }

    /// Sheet-scoped defined names: `_xlnm.Print_Titles` / `_xlnm.Print_Area` become the sheet's print settings;
    /// other names go to `sheet.definedNames`. Names with an invalid sheet index are dropped.
    static func assignLocalNames(_ names: [Int: [String: String]], to wb: inout Workbook) {
        for (index, byName) in names {
            guard wb.sheets.indices.contains(index) else { continue }
            for (name, text) in byName {
                switch name {
                case "_xlnm.Print_Titles": wb.sheets[index].setPrintTitles(text)
                case "_xlnm.Print_Area": wb.sheets[index].setPrintArea(text)
                case "_xlnm._FilterDatabase": break   // implied by <autoFilter>; regenerated on save
                default: wb.sheets[index].definedNames[name] = text
                }
            }
        }
    }

    /// "xl/worksheets/sheet1.xml" → "xl/worksheets/_rels/sheet1.xml.rels".
    static func relsPath(of part: String) -> String {
        let dir = (part as NSString).deletingLastPathComponent
        return (dir.isEmpty ? "" : dir + "/") + "_rels/" + (part as NSString).lastPathComponent + ".rels"
    }

    /// Resolves a relationship target against the directory of its source part: absolute targets drop the leading
    /// The name of a part's root element, read from the bytes without a full parse — enough to tell a
    /// `<chartsheet>` from a `<worksheet>` when the relationship type has already said it is not a worksheet.
    static func rootElement(of data: Data) -> String? {
        guard let text = String(data: data.prefix(4096), encoding: .utf8) else { return nil }
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<") {
            let after = rest.index(after: open)
            guard after < rest.endIndex else { return nil }
            if rest[after] == "?" || rest[after] == "!" {          // declaration, comment, doctype
                guard let close = rest[after...].firstIndex(of: ">") else { return nil }
                rest = rest[rest.index(after: close)...]
                continue
            }
            let name = rest[after...].prefix { !$0.isWhitespace && $0 != ">" && $0 != "/" }
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }

    /// "/", relative ones are joined and `..` segments collapsed ("xl/chartsheets" + "../drawings/d.xml" → "xl/drawings/d.xml").
    static func resolvePart(_ target: String, relativeTo base: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for seg in target.split(separator: "/") {
            if seg == ".." { if !parts.isEmpty { parts.removeLast() } } else if seg != "." { parts.append(String(seg)) }
        }
        return parts.joined(separator: "/")
    }

    static func parseRels(_ zip: ZipArchive, _ path: String) throws -> [Relationship] {
        let p = RelsParser()
        try p.run(try zip.read(path), part: path)
        return p.rels
    }

    /// How many sheets to parse at once (spec Appendix B.41). `ReadOptions.concurrency` says it outright (capped
    /// at the number of grids to parse); left unsaid, the sheets go side by side — up to one per processor
    /// core — only when at least two are to be parsed and their parts expand to `parallelThresholdBytes` between
    /// them, a size the ZIP directory already states, so nothing is read to decide.
    static let parallelThresholdBytes = 4 << 20   // about a hundred thousand cells of SpreadsheetML
    static func concurrency(parsedBytes: [Int], options: ReadOptions) -> Int {
        guard parsedBytes.count > 1 else { return 1 }
        if let asked = options.concurrency { return Swift.max(1, Swift.min(asked, parsedBytes.count)) }
        guard parsedBytes.reduce(0, +) >= parallelThresholdBytes else { return 1 }
        return Swift.max(1, Swift.min(ProcessInfo.processInfo.activeProcessorCount, parsedBytes.count))
    }
}

/// What one sheet's parse needs from the workbook, read-only, so that sheets can be parsed side by side (spec
/// Appendix B.41). Everything here is settled before the first sheet starts: the shared strings are a value, the
/// style caches are prefilled, the archive reads by position.
final class SheetReadContext: @unchecked Sendable {
    let zip: ZipArchive
    let sst: [CellValue]
    let styles: StylesParser
    let epoch: DateEpoch
    let options: ReadOptions
    let contentTypes: [String: String]
    let rels: [Relationship]
    let base: String
    let pivotCaches: [Int: PivotCache]
    let workbookPath: String
    init(zip: ZipArchive, sst: [CellValue], styles: StylesParser, epoch: DateEpoch, options: ReadOptions, contentTypes: [String: String],
         rels: [Relationship], base: String, pivotCaches: [Int: PivotCache], workbookPath: String) {
        self.zip = zip; self.sst = sst; self.styles = styles; self.epoch = epoch; self.options = options
        self.contentTypes = contentTypes; self.rels = rels; self.base = base; self.pivotCaches = pivotCaches; self.workbookPath = workbookPath
    }

    /// One sheet's outcome: the sheet, the parts it consumed, what it had to report — or the error that stopped it.
    struct Result: Sendable {
        var sheet: Sheet?
        var consumed: Set<String> = []
        var warnings: [ConversionWarning] = []
        var error: Error?
    }

    func read(index: Int, info: WorkbookXMLParser.SheetInfo) -> Result {
        var result = Result()
        do { try readSheet(index: index, info: info, into: &result) } catch { result.error = error }
        return result
    }

    private func resolve(_ target: String) -> String { WorkbookReader.resolvePart(target, relativeTo: base) }

    private func readSheet(index: Int, info: WorkbookXMLParser.SheetInfo, into result: inout Result) throws {
        guard let rel = rels.first(where: { $0.id == info.rId }) else { throw SheetError.malformedPart(path: workbookPath, detail: "sheet \(info.name) has no relationship") }
        let part = resolve(rel.target)
        guard zip.contains(part) else { throw SheetError.malformedPart(path: part, detail: "sheet part missing") }
        let sheetRelsPath = WorkbookReader.relsPath(of: part)
        let sheetRels = (try? WorkbookReader.parseRels(zip, sheetRelsPath)) ?? []
        result.consumed.insert(part); result.consumed.insert(sheetRelsPath)

        // a sheet the caller did not ask for is carried as it arrived and never parsed: its part, its
        // relationships (all of them — the part still names them) and everything they point at stay bytes
        if let selection = options.sheets, !selection.includes(name: info.name, index: index), rel.type.hasSuffix(WorkbookReader.relWorksheet) {
            let body = try zip.read(part)
            var sheet = Sheet(name: info.name)
            sheet.state = info.state
            sheet.preserved.partPath = part
            sheet.preserved.relationshipId = info.rId
            sheet.preserved.sheetId = info.sheetId
            sheet.preserved.relationships = sheetRels
            sheet.preserved.foreignSheet = ForeignSheet(root: "worksheet", relationshipType: rel.type,
                                                        contentType: contentTypes[part] ?? "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml",
                                                        body: body)
            sheet.preserved.isUnread = true
            result.warnings.append(ConversionWarning(.degraded, subject: .sheets, sheet: sheet.name,
                                              message: "the sheet was not read (left out by ReadOptions.sheets); it has no cells here and is written back to .xlsx exactly as it arrived"))
            result.sheet = sheet
            return
        }

        // Not every sheet is a grid: SpreadsheetML also has chart sheets, dialog sheets and macro sheets, and
        // the workbook lists them beside the worksheets. Parsing one as a worksheet would find no cells and,
        // worse, writing it back would replace `<chartsheet>` with `<worksheet>` under the same content type —
        // a package that says one thing and holds another. So the part is kept as bytes and reported
        // (spec Appendix B.35).
        if !rel.type.hasSuffix(WorkbookReader.relWorksheet) {
            let body = try zip.read(part)
            var sheet = Sheet(name: info.name)
            sheet.state = info.state
            sheet.preserved.partPath = part
            sheet.preserved.relationshipId = info.rId
            sheet.preserved.sheetId = info.sheetId
            sheet.preserved.relationships = sheetRels.filter { !$0.type.hasSuffix(WorkbookReader.relHyperlink) }
            sheet.preserved.foreignSheet = ForeignSheet(
                root: WorkbookReader.rootElement(of: body) ?? "sheet", relationshipType: rel.type,
                contentType: contentTypes[part] ?? "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml",
                body: body)
            result.warnings.append(ConversionWarning(.degraded, subject: .objects, sheet: sheet.name,
                                              message: "\(sheet.preserved.foreignSheet!.description) has no grid the model can read; "
                                              + "it has no cells here and is written back to .xlsx exactly as it arrived"))
            result.sheet = sheet
            return
        }

        let p = SheetParser(name: info.name, sst: sst, styles: styles, epoch: epoch, dataOnly: options.dataOnly, rels: sheetRels)
        try p.run(stream: try zip.stream(part), part: part)   // a piece at a time: the sheet's XML is never held whole
        var sheet = p.sheet
        sheet.state = info.state
        sheet.preserved.partPath = part
        sheet.preserved.relationshipId = info.rId
        sheet.preserved.sheetId = info.sheetId
        sheet.preserved.relationships = sheetRels.filter {
            !$0.type.hasSuffix(WorkbookReader.relHyperlink) && !$0.type.hasSuffix(WorkbookReader.relTable) && !$0.type.hasSuffix(WorkbookReader.relPivotTable)
        }
        sheet.preserved.rootAttributes = p.rootAttributes

        // named tables: each `<tablePart>` names a relationship, which names a part. The parts stop being
        // opaque, and `<tableParts>` is regenerated from the model rather than kept (`SheetParser` dropped it).
        let sheetDir = (part as NSString).deletingLastPathComponent
        for rel in sheetRels where rel.type.hasSuffix(WorkbookReader.relTable) {
            let tablePart = WorkbookReader.resolvePart(rel.target, relativeTo: sheetDir)
            guard let data = try? zip.read(tablePart) else { continue }
            result.consumed.insert(tablePart); result.consumed.insert(WorkbookReader.relsPath(of: tablePart))
            let tp = TablePartParser()
            try? tp.run(data, part: tablePart)
            guard var t = tp.table else { continue }
            t.partPath = tablePart
            t.relationshipId = rel.id
            sheet.excelTables.append(t)
        }

        // pivot tables: the layout part names the cache it reads by id
        for rel in sheetRels where rel.type.hasSuffix(WorkbookReader.relPivotTable) {
            let pivotPart = WorkbookReader.resolvePart(rel.target, relativeTo: sheetDir)
            guard let data = try? zip.read(pivotPart) else { continue }
            result.consumed.insert(pivotPart); result.consumed.insert(WorkbookReader.relsPath(of: pivotPart))
            let pp = PivotTableParser()
            do { try pp.run(data, part: pivotPart) } catch {
                result.warnings.append(ConversionWarning(.dropped, subject: .objects, sheet: sheet.name,
                                                  message: "\(pivotPart) could not be parsed; the pivot table it describes was skipped"))
                continue
            }
            guard var pivot = pp.table else {
                result.warnings.append(ConversionWarning(.dropped, subject: .objects, sheet: sheet.name,
                                                  message: "\(pivotPart) holds no pivot table definition; it was skipped"))
                continue
            }
            pivot.partPath = pivotPart
            pivot.relationshipId = rel.id
            if let id = pp.cacheId, let cache = pivotCaches[id] { pivot.cache = cache }
            sheet.pivotTables.append(pivot)
        }

        // cell notes: the text from the comments part, the box size from the legacy VML beside it. Both parts
        // stay opaque as well — untouched notes are re-packed byte for byte (spec §6), and only an edit makes
        // the writer generate them afresh.
        if let commentsRel = sheetRels.first(where: { $0.type.hasSuffix(CommentParts.relationshipType) }) {
            let commentsPart = WorkbookReader.resolvePart(commentsRel.target, relativeTo: (part as NSString).deletingLastPathComponent)
            if let data = try? zip.read(commentsPart) {
                var notes = CommentParts.parse(data, part: commentsPart)
                if let vmlRel = sheetRels.first(where: { $0.type.hasSuffix(CommentParts.vmlRelationshipType) }),
                   let vml = try? zip.read(WorkbookReader.resolvePart(vmlRel.target, relativeTo: (part as NSString).deletingLastPathComponent)) {
                    CommentParts.applySizes(from: vml, to: &notes)
                }
                for (ref, note) in notes { sheet[cell: ref].comment = note }
                sheet.preserved.comments = notes
            }
        }
        result.sheet = sheet
    }
}

/// The sheets still to be parsed, handed out one at a time to whoever asks.
final class SheetQueue: @unchecked Sendable {
    private var next = 0
    private let count: Int
    private let lock = NSLock()
    init(count: Int) { self.count = count }
    func take() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard next < count else { return nil }
        next += 1
        return next - 1
    }
}

/// The results of the sheet reads, each put in its own place under a lock.
final class SheetResultsBox: @unchecked Sendable {
    private var stored: [SheetReadContext.Result]
    private let lock = NSLock()
    init(count: Int) { stored = Array(repeating: SheetReadContext.Result(), count: count) }
    func set(_ i: Int, _ r: SheetReadContext.Result) { lock.lock(); stored[i] = r; lock.unlock() }
    var all: [SheetReadContext.Result] { lock.lock(); defer { lock.unlock() }; return stored }
}
