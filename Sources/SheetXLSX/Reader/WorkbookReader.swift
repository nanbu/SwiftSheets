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
        if zip.contains(sstPath) { try sst.run(try zip.read(sstPath), part: sstPath); consumed.insert(sstPath) }
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

        // sheets
        var sheets: [Sheet] = []
        for info in wbParser.sheets {
            guard let rel = rels.first(where: { $0.id == info.rId }) else { throw SheetError.malformedPart(path: workbookPath, detail: "sheet \(info.name) has no relationship") }
            let part = resolve(rel.target)
            guard zip.contains(part) else { throw SheetError.malformedPart(path: part, detail: "sheet part missing") }
            let sheetRelsPath = relsPath(of: part)
            let sheetRels = (try? parseRels(zip, sheetRelsPath)) ?? []
            consumed.insert(part); consumed.insert(sheetRelsPath)

            // Not every sheet is a grid: SpreadsheetML also has chart sheets, dialog sheets and macro sheets, and
            // the workbook lists them beside the worksheets. Parsing one as a worksheet would find no cells and,
            // worse, writing it back would replace `<chartsheet>` with `<worksheet>` under the same content type —
            // a package that says one thing and holds another. So the part is kept as bytes and reported
            // (spec Appendix B.35).
            if !rel.type.hasSuffix(relWorksheet) {
                let body = try zip.read(part)
                var sheet = Sheet(name: info.name)
                sheet.state = info.state
                sheet.preserved.partPath = part
                sheet.preserved.relationshipId = info.rId
                sheet.preserved.sheetId = info.sheetId
                sheet.preserved.relationships = sheetRels.filter { !$0.type.hasSuffix(relHyperlink) }
                sheet.preserved.foreignSheet = ForeignSheet(
                    root: rootElement(of: body) ?? "sheet", relationshipType: rel.type,
                    contentType: ct.overrides[part] ?? "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml",
                    body: body)
                warnings.append(ConversionWarning(.degraded, subject: .objects, sheet: sheet.name,
                                                  message: "\(sheet.preserved.foreignSheet!.description) has no grid the model can read; "
                                                  + "it has no cells here and is written back to .xlsx exactly as it arrived"))
                sheets.append(sheet)
                continue
            }

            let p = SheetParser(name: info.name, sst: sst.strings, styles: styles, epoch: wb.epoch, dataOnly: options.dataOnly, rels: sheetRels)
            try p.run(try zip.read(part), part: part)
            var sheet = p.sheet
            sheet.state = info.state
            sheet.preserved.partPath = part
            sheet.preserved.relationshipId = info.rId
            sheet.preserved.sheetId = info.sheetId
            sheet.preserved.relationships = sheetRels.filter {
                !$0.type.hasSuffix(relHyperlink) && !$0.type.hasSuffix(relTable) && !$0.type.hasSuffix(relPivotTable)
            }
            sheet.preserved.rootAttributes = p.rootAttributes

            // named tables: each `<tablePart>` names a relationship, which names a part. The parts stop being
            // opaque, and `<tableParts>` is regenerated from the model rather than kept (`SheetParser` dropped it).
            let sheetDir = (part as NSString).deletingLastPathComponent
            for rel in sheetRels where rel.type.hasSuffix(relTable) {
                let tablePart = resolvePart(rel.target, relativeTo: sheetDir)
                guard let data = try? zip.read(tablePart) else { continue }
                consumed.insert(tablePart); consumed.insert(relsPath(of: tablePart))
                let tp = TablePartParser()
                try? tp.run(data, part: tablePart)
                guard var t = tp.table else { continue }
                t.partPath = tablePart
                t.relationshipId = rel.id
                sheet.excelTables.append(t)
            }

            // pivot tables: the layout part names the cache it reads by id
            for rel in sheetRels where rel.type.hasSuffix(relPivotTable) {
                let pivotPart = resolvePart(rel.target, relativeTo: sheetDir)
                guard let data = try? zip.read(pivotPart) else { continue }
                consumed.insert(pivotPart); consumed.insert(relsPath(of: pivotPart))
                let pp = PivotTableParser()
                do { try pp.run(data, part: pivotPart) } catch {
                    warnings.append(ConversionWarning(.dropped, subject: .objects, sheet: sheet.name,
                                                      message: "\(pivotPart) could not be parsed; the pivot table it describes was skipped"))
                    continue
                }
                guard var pivot = pp.table else {
                    warnings.append(ConversionWarning(.dropped, subject: .objects, sheet: sheet.name,
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
                let commentsPart = resolvePart(commentsRel.target, relativeTo: (part as NSString).deletingLastPathComponent)
                if let data = try? zip.read(commentsPart) {
                    var notes = CommentParts.parse(data, part: commentsPart)
                    if let vmlRel = sheetRels.first(where: { $0.type.hasSuffix(CommentParts.vmlRelationshipType) }),
                       let vml = try? zip.read(resolvePart(vmlRel.target, relativeTo: (part as NSString).deletingLastPathComponent)) {
                        CommentParts.applySizes(from: vml, to: &notes)
                    }
                    for (ref, note) in notes { sheet[cell: ref].comment = note }
                    sheet.preserved.comments = notes
                }
            }
            sheets.append(sheet)
        }
        guard !sheets.isEmpty else { throw SheetError.invalidWorkbook("workbook has no sheets") }
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
}
