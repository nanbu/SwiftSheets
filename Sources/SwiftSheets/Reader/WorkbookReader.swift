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

        let base = (workbookPath as NSString).deletingLastPathComponent
        let rels = (try? parseRels(zip, base + "/_rels/" + (workbookPath as NSString).lastPathComponent + ".rels")) ?? []
        func resolve(_ target: String) -> String {
            if target.hasPrefix("/") { return String(target.dropFirst()) }
            return base.isEmpty ? target : base + "/" + target
        }
        let sstPath = rels.first { $0.type.hasSuffix("/sharedStrings") }.map { resolve($0.target) } ?? "xl/sharedStrings.xml"
        let stylesPath = rels.first { $0.type.hasSuffix("/styles") }.map { resolve($0.target) } ?? "xl/styles.xml"
        let sst = SharedStringsParser()
        if zip.contains(sstPath) { try sst.run(try zip.read(sstPath), part: sstPath) }
        let styles = StylesParser()
        if zip.contains(stylesPath) { try styles.run(try zip.read(stylesPath), part: stylesPath) }

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

        if let core = rootRels.first(where: { $0.type.hasSuffix("/core-properties") }).map({ $0.target.hasPrefix("/") ? String($0.target.dropFirst()) : $0.target }), zip.contains(core) {
            let cp = CorePropertiesParser()
            try? cp.run(try zip.read(core), part: core)
            wb.properties = cp.props
        }
    }

    static func parseRels(_ zip: ZipArchive, _ path: String) throws -> [Relationship] {
        let p = RelsParser()
        try p.run(try zip.read(path), part: path)
        return p.rels
    }
}
