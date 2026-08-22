import Foundation

/// Resolves the package: _rels/.rels → workbook → its rels → sheets / sharedStrings / styles / docProps.
enum WorkbookReader {
    static func load(_ data: Data, into wb: Workbook, dataOnly: Bool) throws {
        let zip = try ZipArchive(data: data)
        let rootRels = try parseRels(zip, "_rels/.rels")
        let workbookPath = rootRels.first { $0.type.hasSuffix("/officeDocument") }.map { $0.target.hasPrefix("/") ? String($0.target.dropFirst()) : $0.target } ?? "xl/workbook.xml"
        let wbParser = WorkbookXMLParser()
        try wbParser.run(try zip.read(workbookPath), part: workbookPath)
        wb.epoch = wbParser.date1904 ? .mac1904 : .windows1900
        wb.definedNames = wbParser.definedNames
        wb.codeName = wbParser.codeName

        let base = (workbookPath as NSString).deletingLastPathComponent
        let rels = (try? parseRels(zip, base + "/_rels/" + (workbookPath as NSString).lastPathComponent + ".rels")) ?? []
        func resolve(_ target: String) -> String { resolvePart(target, relativeTo: base) }
        let sstPath = rels.first { $0.type.hasSuffix("/sharedStrings") }.map { resolve($0.target) } ?? "xl/sharedStrings.xml"
        let stylesPath = rels.first { $0.type.hasSuffix("/styles") }.map { resolve($0.target) } ?? "xl/styles.xml"
        let sst = SharedStringsParser()
        if zip.contains(sstPath) { try sst.run(try zip.read(sstPath), part: sstPath) }
        let styles = StylesParser()
        if zip.contains(stylesPath) { try styles.run(try zip.read(stylesPath), part: stylesPath) }
        wb.indexedColors = styles.indexedColors

        for info in wbParser.sheets {
            guard let rel = rels.first(where: { $0.id == info.rId }) else { throw SheetsError(.xml, "sheet \(info.name) has no relationship") }
            let part = resolve(rel.target)
            let sheetRelsPath = (part as NSString).deletingLastPathComponent + "/_rels/" + (part as NSString).lastPathComponent + ".rels"
            let sheetRels = (try? parseRels(zip, sheetRelsPath)) ?? []
            let ws = Worksheet(title: info.name, workbook: wb)
            ws.state = info.state
            let p = SheetParser(ws: ws, sst: sst.strings, styles: styles, epoch: wb.epoch, dataOnly: dataOnly, rels: sheetRels)
            try p.run(try zip.read(part), part: part)
            wb.addLoadedSheet(ws)
        }
        guard !wb.worksheets.isEmpty else { throw SheetsError(.invalid, "workbook has no sheets") }
        wb.activeIndex = min(wbParser.activeTab, wb.worksheets.count - 1)
        assignLocalNames(wbParser.localNames, to: wb)

        if let core = rootRels.first(where: { $0.type.hasSuffix("/core-properties") }).map({ $0.target.hasPrefix("/") ? String($0.target.dropFirst()) : $0.target }), zip.contains(core) {
            let cp = CorePropertiesParser()
            try? cp.run(try zip.read(core), part: core)
            wb.properties = cp.props
        }
    }

    /// Sheet-scoped defined names (openpyxl `assign_names`): `_xlnm.Print_Titles` / `_xlnm.Print_Area` become the
    /// sheet's print settings; other names go to `ws.definedNames`. Names with an invalid sheet index are dropped.
    static func assignLocalNames(_ names: [Int: [String: String]], to wb: Workbook) {
        for (index, byName) in names {
            guard wb.worksheets.indices.contains(index) else { continue }
            let ws = wb.worksheets[index]
            for (name, text) in byName {
                switch name {
                case "_xlnm.Print_Titles": ws.setPrintTitles(text)
                case "_xlnm.Print_Area": ws.setPrintArea(text)
                case "_xlnm._FilterDatabase": break   // implied by <autoFilter>; regenerated on save
                default: ws.definedNames[name] = text
                }
            }
        }
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
