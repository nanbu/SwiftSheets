import Foundation
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
    static let relHyperlink = "/hyperlink"
    static let relVBA = "/vbaProject"

    static func read(_ data: Data, options: ReadOptions) throws -> Workbook {
        let zip = try ZipArchive(data: data)
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
        wb.indexedColors = styles.indexedColors
        wb.preserved.styleFragments = styles.fragments
        if zip.contains(stylesPath) { wb.preserved.styleTables = styles.styleTables }
        if let calc = rels.first(where: { $0.type.hasSuffix(relCalcChain) }) { consumed.insert(resolve(calc.target)) }   // always dropped (Excel rebuilds it)

        // sheets
        var sheets: [Sheet] = []
        for info in wbParser.sheets {
            guard let rel = rels.first(where: { $0.id == info.rId }) else { throw SheetError.malformedPart(path: workbookPath, detail: "sheet \(info.name) has no relationship") }
            let part = resolve(rel.target)
            guard zip.contains(part) else { throw SheetError.malformedPart(path: part, detail: "sheet part missing") }
            let sheetRelsPath = relsPath(of: part)
            let sheetRels = (try? parseRels(zip, sheetRelsPath)) ?? []
            consumed.insert(part); consumed.insert(sheetRelsPath)
            let p = SheetParser(name: info.name, sst: sst.strings, styles: styles, epoch: wb.epoch, dataOnly: options.dataOnly, rels: sheetRels)
            try p.run(try zip.read(part), part: part)
            var sheet = p.sheet
            sheet.state = info.state
            sheet.preserved.partPath = part
            sheet.preserved.relationshipId = info.rId
            sheet.preserved.sheetId = info.sheetId
            sheet.preserved.relationships = sheetRels.filter { !$0.type.hasSuffix(relHyperlink) }
            sheet.preserved.rootAttributes = p.rootAttributes
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
        wb.sourceInfo = source
        wb.preserved.application = source.application

        // everything else: kept byte for byte, with the relationships and content types that declare it
        if options.preserveUnknownParts {
            wb.preserved.relationships[workbookPath] = rels.filter { r in
                ![relWorksheet, relSharedStrings, relStyles, relCalcChain].contains { r.type.hasSuffix($0) }
            }
            wb.preserved.relationships["_rels/.rels"] = rootRels.filter { r in ![relOfficeDocument, relCore, relApp].contains { r.type.hasSuffix($0) } }
            wb.preserved.contentTypeDefaults = ct.defaults
            for name in zip.entries.keys where !consumed.contains(name) && !name.hasSuffix("/") {
                wb.preserved.opaqueParts[name] = try zip.read(name)
            }
            wb.preserved.contentTypeOverrides = ct.overrides.filter { wb.preserved.opaqueParts[$0.key] != nil }
        }
        return wb
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
