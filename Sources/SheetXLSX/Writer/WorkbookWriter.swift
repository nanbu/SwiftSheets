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

/// Text on its way to a compressor, handed over in pieces of about 64 KiB rather than one string per part.
final class PieceBuffer {
    static let pieceSize = 64 * 1024
    private var pending = Data()
    private let sink: (Data) throws -> Void
    init(_ sink: @escaping (Data) throws -> Void) { self.sink = sink }
    convenience init(_ text: @escaping (String) -> Void) { self.init { text(String(decoding: $0, as: UTF8.self)) } }
    func write(_ s: String) throws {
        pending.append(contentsOf: s.utf8)
        if pending.count >= PieceBuffer.pieceSize { try flush() }
    }
    func flush() throws {
        guard !pending.isEmpty else { return }
        try sink(pending)
        pending.removeAll(keepingCapacity: true)
    }
}

/// Collects what the write could not express.
final class WarningSink {
    var warnings: [ConversionWarning] = []
    func add(_ kind: ConversionWarning.Kind, subject: ConversionWarning.Subject = .other, sheet: String? = nil,
             at location: CellRef? = nil, _ message: String) {
        warnings.append(ConversionWarning(kind, subject: subject, sheet: sheet, location: location, message: message))
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
        styles.registerNamedStyles(wb.namedStyles)
        styles.applyDifferentialStyles(sameFamily ? wb.differentialStyles : [])
        if sameFamily { styles.fragments = preserved.styleFragments }
        let strings = SharedStringTable()

        // opaque parts that travel along (VBA only into .xlsm)
        var opaque: [String: OpaquePart] = sameFamily ? preserved.parts : [:]
        var droppedRelTypes: [String] = []
        if format == .xlsx {
            let vba = opaque.keys.filter { $0.hasSuffix("vbaProject.bin") || $0.hasSuffix("vbaProjectSignature.bin") || $0.hasSuffix("vbaData.xml") }
            if !vba.isEmpty {
                for k in vba { opaque[k] = nil }
                droppedRelTypes = ["/vbaProject", "/vbaProjectSignature"]
                sink.add(.dropped, subject: .macros, "VBA project dropped: macros cannot be kept in .xlsx (write .xlsm to keep them)")
            }
        }
        if !sameFamily, preserved.opaquePartCount > 0 {
            sink.add(.dropped, subject: .objects, "\(preserved.opaquePartCount) part(s) preserved from the \(preserved.sourceFormat?.rawValue ?? "source") file cannot be carried into XLSX")
        }
        // a Numbers word with no OOXML spelling: the value under the control is written, the control is named
        for sheet in wb.sheets {
            let controls = sheet.tables.reduce(0) { $0 + $1.cells.values.filter { $0.control != nil }.count }
            if controls > 0 {
                sink.add(.dropped, subject: .other, sheet: sheet.name, "\(controls) cell control(s) (checkbox, stepper, slider, rating) dropped: Excel has no cell controls — the value is kept (write .numbers to keep the control)")
            }
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

        // cell notes: a sheet whose notes are exactly the ones it was read with keeps its source parts (byte for
        // byte, spec §6); any other sheet with notes gets a freshly generated comments part and legacy VML.
        var commentPlans: [Int: CommentPlan] = [:]
        for (i, sheet) in wb.sheets.enumerated() {
            let notes = sheet.notes
            let sheetDir = (plans[i].path as NSString).deletingLastPathComponent
            let sheetRels = sameFamily ? sheet.preserved.relationships : []
            func sourcePath(_ type: String) -> String? {
                sheetRels.first { $0.type.hasSuffix(type) }.map { WorkbookReader.resolvePart($0.target, relativeTo: sheetDir) }
            }
            let sourceComments = sourcePath(CommentParts.relationshipType), sourceVML = sourcePath(CommentParts.vmlRelationshipType)
            let asRead = sameFamily ? sheet.preserved.comments : [:]
            if sourceComments != nil, Dictionary(notes.map { ($0.ref, $0.note) }, uniquingKeysWith: { a, _ in a }) == asRead { continue }

            // the source parts stop being authoritative the moment the model disagrees with them
            for path in [sourceComments, sourceVML].compactMap({ $0 }) {
                if let vml = sourceVML, path == vml, let bytes = opaque[vml]?.data, CommentParts.holdsNonNoteShapes(bytes) {
                    sink.add(.dropped, subject: .objects, sheet: sheet.name,
                             "legacy drawing shapes other than cell notes (form controls, buttons) were dropped: the part had to be regenerated for the notes")
                }
                opaque[path] = nil
                usedPaths.remove(path)
            }
            guard !notes.isEmpty else { continue }
            func path(_ existing: String?, _ pattern: (Int) -> String) -> String {
                if let existing { usedPaths.insert(existing); return existing }
                var n = 1
                while usedPaths.contains(pattern(n)) { n += 1 }
                usedPaths.insert(pattern(n))
                return pattern(n)
            }
            commentPlans[i] = CommentPlan(commentsPath: path(sourceComments) { "xl/comments/comment\($0).xml" },
                                          vmlPath: path(sourceVML) { "xl/drawings/commentsDrawing\($0).vml" },
                                          notes: notes)
        }

        // pictures (spec Appendix B.32): media goes into the package once per image; a sheet that already has a
        // drawing part gets the anchors spliced into the preserved bytes, a sheet without one gets a fresh part.
        var imagePlans: [Int: ImagePlan] = [:]
        var imageExtensions = Set<String>()
        var nextMedia = 1
        for path in usedPaths where path.hasPrefix("xl/media/image") {
            let stem = path.dropFirst("xl/media/image".count)
            if let n = Int(stem.prefix(while: \.isNumber)) { nextMedia = max(nextMedia, n + 1) }
        }
        var nextDrawing = 1
        for path in usedPaths where path.hasPrefix("xl/drawings/drawing") {
            let stem = path.dropFirst("xl/drawings/drawing".count)
            if let n = Int(stem.prefix(while: \.isNumber)) { nextDrawing = max(nextDrawing, n + 1) }
        }
        var nextChart = 1
        for path in usedPaths where path.hasPrefix("xl/charts/chart") {
            let stem = path.dropFirst("xl/charts/chart".count)
            if let n = Int(stem.prefix(while: \.isNumber)) { nextChart = max(nextChart, n + 1) }
        }
        var generatedOverrides: [String: String] = [:]
        for (i, sheet) in wb.sheets.enumerated() where !sheet.images.isEmpty || !sheet.charts.isEmpty {
            // every image becomes a media part; every chart with series becomes a chart part (B.34)
            var entries: [(type: String, target: String)] = []
            for image in sheet.images {
                let path = "xl/media/image\(nextMedia).\(image.format.rawValue)"
                nextMedia += 1
                usedPaths.insert(path)
                opaque[path] = .bytes(image.data)
                imageExtensions.insert(image.format.rawValue)
                entries.append((DrawingParts.imageRelationshipType, "../media/" + (path as NSString).lastPathComponent))
            }
            var charts: [Chart] = []
            for chart in sheet.charts {
                guard !chart.series.isEmpty, chart.anchor != nil else {
                    sink.add(.dropped, subject: .objects, sheet: sheet.name, "a \(chart.kind.rawValue) chart with no series was not written")
                    continue
                }
                let path = "xl/charts/chart\(nextChart).xml"
                nextChart += 1
                usedPaths.insert(path)
                opaque[path] = .bytes(Data(ChartParts.chartXML(chart, sheetName: sheet.name).utf8))
                generatedOverrides[path] = ChartParts.contentType
                entries.append((ChartParts.relationshipType, "../charts/" + (path as NSString).lastPathComponent))
                charts.append(chart)
            }
            guard !entries.isEmpty else { continue }
            func anchors(_ ids: [String], firstShapeID: (String) -> Int) -> [String] {
                var out: [String] = []
                for (n, image) in sheet.images.enumerated() {
                    out.append(DrawingParts.anchorXML(image, shapeID: firstShapeID(ids[n]), relID: ids[n],
                                                      cellSize: DrawingParts.cellSize(of: sheet, at: image.anchor)))
                }
                for (n, chart) in charts.enumerated() {
                    let id = ids[sheet.images.count + n]
                    out.append(ChartParts.anchorXML(over: chart.anchor!, shapeID: firstShapeID(id), relID: id))
                }
                return out
            }
            // the sheet's existing drawing, if the source had one and it survived into this write
            let sheetDir = (plans[i].path as NSString).deletingLastPathComponent
            let existing: String? = !sameFamily ? nil : sheet.preserved.relationships
                .first { $0.type.hasSuffix(DrawingParts.relationshipType) }
                .map { WorkbookReader.resolvePart($0.target, relativeTo: sheetDir) }
                .flatMap { opaque[$0] != nil ? $0 : nil }
            if let drawingPath = existing {
                let relsPath = WorkbookReader.relsPath(of: drawingPath)
                guard let patched = DrawingParts.appendingRelationships(entries: entries, to: opaque[relsPath]?.data),
                      let spliced = DrawingParts.appendingAnchors(
                          anchors(patched.ids, firstShapeID: { 1000 + (Int($0.dropFirst(3)) ?? 0) }), to: opaque[drawingPath]!.data)
                else {
                    sink.add(.dropped, subject: .objects, sheet: sheet.name,
                             "\(entries.count) image(s)/chart(s) not written: the sheet's existing drawing part could not be extended")
                    continue
                }
                opaque[drawingPath] = .bytes(spliced)
                opaque[relsPath] = .bytes(patched.data)
            } else {
                let drawingPath = "xl/drawings/drawing\(nextDrawing).xml"
                nextDrawing += 1
                usedPaths.insert(drawingPath)
                guard let rels = DrawingParts.appendingRelationships(entries: entries, to: nil) else { continue }
                imagePlans[i] = ImagePlan(newDrawing: (drawingPath,
                                                      DrawingParts.drawingXML(anchors: anchors(rels.ids, firstShapeID: { 1 + (Int($0.dropFirst(3)) ?? 0) })),
                                                      String(data: rels.data, encoding: .utf8)!))
            }
        }

        // named tables: each gets a part of its own, an id unique across the workbook, and a sheet relationship.
        // A table read from a file keeps its part path and id; a new one is numbered after the highest in use.
        var usedTableIDs = Set<Int>()
        var nextTableID = (wb.sheets.flatMap { $0.excelTables.compactMap(\.sourceID) }.max() ?? 0) + 1
        var tablePlans: [Int: [TablePlan]] = [:]
        var takenTableNames = Set<String>()
        for (i, sheet) in wb.sheets.enumerated() {
            for table in sheet.excelTables {
                if let reason = table.validationError() {
                    sink.add(.dropped, subject: .tables, sheet: sheet.name, "named table not written: \(reason)")
                    continue
                }
                if !takenTableNames.insert(table.name.lowercased()).inserted {
                    sink.add(.dropped, subject: .tables, sheet: sheet.name,
                             "named table \"\(table.name)\" not written: another table in this workbook already has that name")
                    continue
                }
                var path = table.partPath.flatMap { sameFamily && !usedPaths.contains($0) ? $0 : nil }
                if path == nil { var n = 1; while usedPaths.contains("xl/tables/table\(n).xml") { n += 1 }; path = "xl/tables/table\(n).xml" }
                usedPaths.insert(path!)
                var id = table.sourceID.flatMap { sameFamily && !usedTableIDs.contains($0) ? $0 : nil }
                if id == nil { while usedTableIDs.contains(nextTableID) { nextTableID += 1 }; id = nextTableID }
                usedTableIDs.insert(id!)
                tablePlans[i, default: []].append(TablePlan(table: table, path: path!,
                                                            relationshipId: sameFamily ? (table.relationshipId ?? "") : "",
                                                            id: id!))
            }
        }

        // Differential formats are addressed by index from several places at once, and a file may point two rules
        // at one entry. Editing such a rule must not repaint the others, so an entry with more than one claim on it
        // is never overwritten in place — the edited rule gets an entry of its own instead.
        var dxfClaims: [Int: Int] = [:]
        for sheet in wb.sheets {
            for block in sheet.conditionalFormatting {
                for rule in block.rules { if let id = rule.sourceStyleID { dxfClaims[id, default: 0] += 1 } }
            }
            for column in sheet.filterColumns {
                if let id = column.colorFilter?.differentialStyleID { dxfClaims[id, default: 0] += 1 }
            }
            for table in sheet.excelTables {
                for column in table.filterColumns {
                    if let id = column.colorFilter?.differentialStyleID { dxfClaims[id, default: 0] += 1 }
                }
            }
        }
        let sharedSourceStyles = Set(dxfClaims.filter { $0.value > 1 }.keys)

        // pivot tables: a layout part per table on its sheet, a cache definition per table in the workbook, and a
        // record part beside each definition. Each keeps its source paths, ids and relationship ids where it can.
        var usedCacheIDs = Set<Int>()
        var nextCacheID = (wb.sheets.flatMap { $0.pivotTables.compactMap(\.cache.cacheId) }.max() ?? 0) + 1
        var pivotPlans: [Int: [PivotPlan]] = [:]
        var cachePlans: [CachePlan] = []
        for (i, sheet) in wb.sheets.enumerated() {
            for pivot in sheet.pivotTables {
                if let reason = pivot.validationError() {
                    sink.add(.dropped, subject: .objects, sheet: sheet.name, "pivot table not written: \(reason)")
                    continue
                }
                var tablePath = pivot.partPath.flatMap { sameFamily && !usedPaths.contains($0) ? $0 : nil }
                if tablePath == nil {
                    var n = 1
                    while usedPaths.contains("xl/pivotTables/pivotTable\(n).xml") { n += 1 }
                    tablePath = "xl/pivotTables/pivotTable\(n).xml"
                }
                usedPaths.insert(tablePath!)

                var cacheId = pivot.cache.cacheId.flatMap { sameFamily && !usedCacheIDs.contains($0) ? $0 : nil }
                if cacheId == nil { while usedCacheIDs.contains(nextCacheID) { nextCacheID += 1 }; cacheId = nextCacheID }
                usedCacheIDs.insert(cacheId!)

                var definitionPath = pivot.cache.definitionPath.flatMap { sameFamily && !usedPaths.contains($0) ? $0 : nil }
                if definitionPath == nil {
                    var n = 1
                    while usedPaths.contains("xl/pivotCache/pivotCacheDefinition\(n).xml") { n += 1 }
                    definitionPath = "xl/pivotCache/pivotCacheDefinition\(n).xml"
                }
                usedPaths.insert(definitionPath!)
                // a record part only when the source file brought one: a cache SwiftSheets generates says
                // "no data saved, refresh when opened" instead of inventing rows it has not computed
                var recordsPath: String? = nil
                if pivot.cache.recordsXML != nil {
                    recordsPath = pivot.cache.recordsPath.flatMap { sameFamily && !usedPaths.contains($0) ? $0 : nil }
                    if recordsPath == nil {
                        var n = 1
                        while usedPaths.contains("xl/pivotCache/pivotCacheRecords\(n).xml") { n += 1 }
                        recordsPath = "xl/pivotCache/pivotCacheRecords\(n).xml"
                    }
                    usedPaths.insert(recordsPath!)
                }

                var cacheRelID = pivot.cache.relationshipId.flatMap { sameFamily && !usedIds.contains($0) ? $0 : nil }
                if let r = cacheRelID { usedIds.insert(r) } else { cacheRelID = freshId() }

                cachePlans.append(CachePlan(cache: pivot.cache, cacheId: cacheId!, definitionPath: definitionPath!,
                                            recordsPath: recordsPath, relationshipId: cacheRelID!))
                pivotPlans[i, default: []].append(PivotPlan(pivot: pivot, path: tablePath!, cacheId: cacheId!,
                                                            cacheDefinitionPath: definitionPath!,
                                                            relationshipId: sameFamily ? (pivot.relationshipId ?? "") : ""))
            }
        }

        // A sheet that is not a grid is written back verbatim, so anything put into it here has nowhere to go.
        for sheet in wb.sheets {
            guard let foreign = sheet.preserved.foreignSheet else { continue }
            guard sameFamily else {
                sink.add(.dropped, subject: .objects, sheet: sheet.name,
                         "\(foreign.description) cannot be rebuilt from the model; the sheet is written as an empty worksheet")
                continue
            }
            if !sheet.cells.isEmpty {
                sink.add(.dropped, subject: .objects, sheet: sheet.name,
                         "\(sheet.cells.count) cell(s) written into \(foreign.description) are not saved: it has no grid, "
                         + "and the sheet is written back as it arrived")
            }
        }

        // sheets first: they register styles and strings
        var sheetParts: [SheetPart] = []
        for (i, sheet) in wb.sheets.enumerated() {
            sheetParts.append(sheetPart(sheet, epoch: wb.epoch, styles: styles, strings: strings, preserve: sameFamily,
                                        isActive: i == wb.activeIndex, comments: commentPlans[i],
                                        tables: tablePlans[i] ?? [], pivots: pivotPlans[i] ?? [],
                                        images: imagePlans[i], sharedSourceStyles: sharedSourceStyles, sink: sink))
        }
        let generatedNoteParts = sheetParts.flatMap(\.parts)
        // styles reference theme colours, so a theme part must exist: keep the source's, or ship the default one
        let preservedTheme = opaque.keys.first { $0.hasPrefix("xl/theme/") }
        let themePath = preservedTheme ?? Theme.partPath
        let needsGeneratedTheme = preservedTheme == nil
        let stylesId = freshId()
        let themeId = needsGeneratedTheme ? freshId() : nil
        // the rows are written after the workbook's own parts now, so whether a shared-string table will exist
        // is decided from the model: any text value outside a formula goes into it
        let hasStrings = wb.sheets.contains { sheet in
            sheet.preserved.foreignSheet == nil && sheet.table.cells.values.contains { cell in
                switch cell.value { case .text?, .richText?: return true; default: return false }
            }
        }
        let sstId = hasStrings ? freshId() : nil

        // [Content_Types].xml
        var defaults = ["rels": "application/vnd.openxmlformats-package.relationships+xml", "xml": "application/xml"]
        if sameFamily { for (k, v) in preserved.contentTypeDefaults where defaults[k] == nil { defaults[k] = v } }
        var overrides: [String: String] = [:]
        overrides["xl/workbook.xml"] = format == .xlsm ? ctWorkbookMacro : ctWorkbook
        for (sheet, p) in zip(wb.sheets, plans) {
            overrides[p.path] = (sameFamily ? sheet.preserved.foreignSheet?.contentType : nil)
                ?? "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"
        }
        overrides["xl/styles.xml"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"
        if hasStrings { overrides["xl/sharedStrings.xml"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml" }
        overrides[themePath] = Theme.contentType
        overrides["docProps/core.xml"] = "application/vnd.openxmlformats-package.core-properties+xml"
        overrides["docProps/app.xml"] = "application/vnd.openxmlformats-officedocument.extended-properties+xml"
        if !wb.customProperties.isEmpty { overrides[customPropertiesPath] = ctCustomProperties }
        if sameFamily { for (k, v) in preserved.contentTypeOverrides where opaque[k] != nil { overrides[k] = v } }
        for part in generatedNoteParts where !part.path.contains("/_rels/") {
            if part.path.hasSuffix(".vml") { defaults["vml"] = CommentParts.vmlContentType }
            else if part.path.hasPrefix("xl/tables/") { overrides[part.path] = ctTable }
            else if part.path.hasPrefix("xl/pivotTables/") { overrides[part.path] = PivotParts.ctTable }
            else if part.path.hasPrefix("xl/drawings/") { overrides[part.path] = DrawingParts.contentType }
            else { overrides[part.path] = CommentParts.contentType }
        }
        for ext in imageExtensions.sorted() where defaults[ext] == nil {
            defaults[ext] = SheetImage.Format(rawValue: ext)!.contentType
        }
        for (path, type) in generatedOverrides { overrides[path] = type }
        for plan in cachePlans {
            overrides[plan.definitionPath] = PivotParts.ctCacheDefinition
            if let records = plan.recordsPath { overrides[records] = PivotParts.ctCacheRecords }
        }
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
        rootRels += "<Relationship Id=\"rId\(rootNext)\" Type=\"\(XMLWriter.nsRel)/extended-properties\" Target=\"docProps/app.xml\"/>"; rootNext += 1
        if !wb.customProperties.isEmpty {
            rootRels += "<Relationship Id=\"rId\(rootNext)\" Type=\"\(XMLWriter.nsRel)/custom-properties\" Target=\"\(customPropertiesPath.hasPrefix("docProps/") ? customPropertiesPath : "/" + customPropertiesPath)\"/>"
            archive.add(customPropertiesPath, Data((XMLWriter.header + customPropertiesXML(wb.customProperties)).utf8))
        }
        rootRels += "</Relationships>"
        archive.add("_rels/.rels", Data(rootRels.utf8))
        archive.add("docProps/app.xml", Data((XMLWriter.header + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>\(SwiftSheetsInfo.name)</Application><AppVersion>\(SwiftSheetsInfo.appVersion)</AppVersion></Properties>").utf8))
        archive.add("docProps/core.xml", Data((XMLWriter.header + coreXML(wb.metadata)).utf8))

        // xl/workbook.xml
        var generated: [(String, String)] = []
        var pr = sameFamily ? preserved.workbookPrAttributes : [:]
        if wb.epoch == .mac1904 { pr["date1904"] = "1" } else { pr["date1904"] = nil }
        if let cn = wb.codeName { pr["codeName"] = cn }
        generated.append(("workbookPr", "<workbookPr" + pr.keys.sorted().map { " \($0)=\"\(XML.esc(pr[$0]!))\"" }.joined() + "/>"))
        if !wb.protection.isDefault {
            let p = wb.protection
            var x = "<workbookProtection"
            x += XML.attr("workbookPassword", p.passwordHash) + XML.attr("revisionsPassword", p.revisionsPasswordHash)
            x += XML.attr("workbookAlgorithmName", p.algorithmName) + XML.attr("workbookHashValue", p.hashValue)
            x += XML.attr("workbookSaltValue", p.saltValue) + XML.attr("workbookSpinCount", p.spinCount)
            x += XML.attr("lockStructure", p.lockStructure) + XML.attr("lockWindows", p.lockWindows)
            x += XML.attr("lockRevision", p.lockRevision)
            generated.append(("workbookProtection", x + "/>"))
        }
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
        if !cachePlans.isEmpty {
            generated.append(("pivotCaches", "<pivotCaches>" + cachePlans.map {
                "<pivotCache cacheId=\"\($0.cacheId)\" r:id=\"\($0.relationshipId)\"/>"
            }.joined() + "</pivotCaches>"))
        }
        let wbFragments = sameFamily ? preserved.workbookFragments.filter { $0.element != "calcPr" } : []
        var wbx = XMLWriter.header + "<workbook" + XMLWriter.rootAttributes(sameFamily ? preserved.workbookRootAttributes : [:], defaults: ["xmlns": XMLWriter.nsMain, "xmlns:r": XMLWriter.nsRel]) + ">"
        wbx += XMLWriter.ordered(generated, fragments: wbFragments, order: workbookOrder)
        wbx += "</workbook>"
        archive.add("xl/workbook.xml", Data(wbx.utf8))

        // xl/_rels/workbook.xml.rels
        var rels = XMLWriter.header + "<Relationships xmlns=\"\(XMLWriter.nsPkgRel)\">"
        for (sheet, plan) in zip(wb.sheets, plans) {
            let type = (sameFamily ? sheet.preserved.foreignSheet?.relationshipType : nil) ?? "\(XMLWriter.nsRel)/worksheet"
            rels += "<Relationship Id=\"\(plan.rId)\" Type=\"\(XML.esc(type))\" Target=\"\(XML.esc(relativeTarget(plan.path, from: "xl")))\"/>"
        }
        if let themeId { rels += "<Relationship Id=\"\(themeId)\" Type=\"\(XMLWriter.nsRel)\(Theme.relationshipType)\" Target=\"\(XML.esc(relativeTarget(themePath, from: "xl")))\"/>" }
        rels += "<Relationship Id=\"\(stylesId)\" Type=\"\(XMLWriter.nsRel)/styles\" Target=\"styles.xml\"/>"
        if let sstId { rels += "<Relationship Id=\"\(sstId)\" Type=\"\(XMLWriter.nsRel)/sharedStrings\" Target=\"sharedStrings.xml\"/>" }
        for plan in cachePlans {
            rels += "<Relationship Id=\"\(plan.relationshipId)\" Type=\"\(XMLWriter.nsRel)\(PivotParts.relCacheDefinition)\" Target=\"\(XML.esc(relativeTarget(plan.definitionPath, from: "xl")))\"/>"
        }
        for r in wbRels where r.targetMode == "External" || opaque[WorkbookReader.resolvePart(r.target, relativeTo: "xl")] != nil { rels += relationshipXML(r) }
        // (a preserved theme keeps its own relationship above; a generated one was added with `themeId`)
        rels += "</Relationships>"
        archive.add("xl/_rels/workbook.xml.rels", Data(rels.utf8))

        for ((sheet, part), plan) in zip(zip(wb.sheets, sheetParts), plans) {
            if sameFamily, let foreign = sheet.preserved.foreignSheet {
                archive.add(plan.path, foreign.body)      // not a grid: it leaves as the bytes it arrived as
            } else {
                // the rows go to the compressor a piece at a time; the sheet's XML is never held whole
                try archive.beginEntry(plan.path)
                let buffer = PieceBuffer { try archive.write($0) }
                try buffer.write(XMLWriter.header)
                try part.write(into: buffer)
                try buffer.flush()
                try archive.endEntry()
            }
            if let r = part.rels { archive.add(WorkbookReader.relsPath(of: plan.path), Data((XMLWriter.header + r).utf8)) }
        }
        for part in generatedNoteParts { archive.add(part.path, part.data) }
        for plan in cachePlans {
            archive.add(plan.definitionPath, Data((XMLWriter.header
                + PivotParts.cacheDefinitionXML(plan.cache, recordsRelationshipId: plan.recordsPath == nil ? nil : "rId1")).utf8))
            guard let records = plan.recordsPath, let bytes = plan.cache.recordsXML else { continue }
            let definitionDir = (plan.definitionPath as NSString).deletingLastPathComponent
            archive.add(WorkbookReader.relsPath(of: plan.definitionPath), Data((XMLWriter.header
                + "<Relationships xmlns=\"\(XMLWriter.nsPkgRel)\"><Relationship Id=\"rId1\" Type=\"\(XMLWriter.nsRel)\(PivotParts.relCacheRecords)\" Target=\"\(XML.esc(relativeTarget(records, from: definitionDir)))\"/></Relationships>").utf8))
            archive.add(records, bytes)
        }
        if needsGeneratedTheme { archive.add(Theme.partPath, Data((XMLWriter.header + Theme.xml).utf8)) }
        if hasStrings { archive.add("xl/sharedStrings.xml", Data((XMLWriter.header + strings.xml()).utf8)) }
        archive.add("xl/styles.xml", Data((XMLWriter.header + styles.xml()).utf8))
        for name in opaque.keys.sorted() { archive.add(name, part: opaque[name]!) }

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

    static let customPropertiesPath = "docProps/custom.xml"
    static let ctCustomProperties = "application/vnd.openxmlformats-officedocument.custom-properties+xml"
    static let nsCustomProperties = "http://schemas.openxmlformats.org/officeDocument/2006/custom-properties"
    static let nsVariantTypes = "http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"

    /// docProps/custom.xml. `fmtid` is the one constant every writer uses, and `pid` numbers the properties from 2
    /// (0 and 1 are reserved by the format).
    static func customPropertiesXML(_ properties: CustomDocumentProperties) -> String {
        var s = "<Properties xmlns=\"\(nsCustomProperties)\" xmlns:vt=\"\(nsVariantTypes)\">"
        for (i, p) in properties.enumerated() {
            s += "<property fmtid=\"{D5CDD505-2E9C-101B-9397-08002B2CF9AE}\" pid=\"\(i + 2)\" name=\"\(XML.esc(p.name))\""
            switch p.value {
            case .link(let target): s += " linkTarget=\"\(XML.esc(target))\"><vt:lpwstr/>"
            case .text(let v): s += "><vt:lpwstr>\(XML.esc(v))</vt:lpwstr>"
            case .integer(let v): s += "><vt:i4>\(v)</vt:i4>"
            case .number(let v): s += "><vt:r8>\(XML.num(v))</vt:r8>"
            case .bool(let v): s += "><vt:bool>\(v ? 1 : 0)</vt:bool>"
            case .date(let v):
                let f = ISO8601DateFormatter()
                s += "><vt:filetime>\(f.string(from: v))</vt:filetime>"
            }
            s += "</property>"
        }
        return s + "</Properties>"
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
    /// One `<dataValidation>`. `hideDropDown` is written to the inverted `showDropDown` attribute it means.
    static func dataValidationXML(_ dv: DataValidation) -> String {
        var s = "<dataValidation"
        if dv.kind != .none { s += " type=\"\(dv.kind.rawValue)\"" }
        s += XML.attr("errorStyle", dv.errorStyle?.rawValue)
        s += XML.attr("imeMode", dv.imeMode)
        s += XML.attr("operator", dv.operator?.rawValue)
        s += XML.attr("allowBlank", dv.allowBlank)
        s += XML.attr("showDropDown", dv.hideDropDown)          // 1 HIDES the arrow — the attribute is inverted
        s += XML.attr("showInputMessage", dv.showInputMessage)
        s += XML.attr("showErrorMessage", dv.showErrorMessage)
        s += XML.attr("errorTitle", dv.errorTitle)
        s += XML.attr("error", dv.error)
        s += XML.attr("promptTitle", dv.promptTitle)
        s += XML.attr("prompt", dv.prompt)
        s += " sqref=\"\(dv.ranges.description)\""
        var inner = ""
        if let f = dv.formula1 { inner += "<formula1>\(XML.esc(f))</formula1>" }
        if let f = dv.formula2 { inner += "<formula2>\(XML.esc(f))</formula2>" }
        return inner.isEmpty ? s + "/>" : s + ">" + inner + "</dataValidation>"
    }

    /// `<filterColumn>` / `<sortState>` — the children of `<autoFilter>` the model carries. A column filters in
    /// exactly one way (the schema's own `xsd:choice`), so only the first kind it sets is written.
    static func filterChildrenXML(_ ws: Sheet, sheetName: String? = nil, sink: WarningSink? = nil) -> String {
        var s = ""
        for column in ws.filterColumns.sorted(by: { $0.column < $1.column }) {
            if column.criterionCount > 1 {
                sink?.add(.degraded, subject: .formatting, sheet: sheetName,
                          "auto-filter column \(column.column) sets \(column.criterionCount) kinds of filter; a column filters one way, so only the first was written")
            }
            s += "<filterColumn colId=\"\(column.column)\"\(column.buttonHidden ? " hiddenButton=\"1\"" : "")\(column.buttonShown ? "" : " showButton=\"0\"")"
            let hasValues = !column.values.isEmpty || column.includesBlanks || !column.dateGroups.isEmpty
            guard hasValues || !column.conditions.isEmpty || column.top10 != nil || column.dynamicFilter != nil
                    || column.colorFilter != nil || column.iconFilter != nil else { s += "/>"; continue }
            s += ">"
            if hasValues {
                s += "<filters\(column.includesBlanks ? " blank=\"1\"" : "")\(XML.attr("calendarType", column.calendarType))"
                let inner = column.values.map { "<filter val=\"\(XML.esc($0))\"/>" }.joined()
                    + column.dateGroups.map(dateGroupXML).joined()
                s += inner.isEmpty ? "/>" : ">" + inner + "</filters>"
            } else if !column.conditions.isEmpty {
                s += "<customFilters\(column.matchesAllConditions ? " and=\"1\"" : "")>"
                s += column.conditions.map { "<customFilter operator=\"\($0.comparison.rawValue)\" val=\"\(XML.esc($0.value))\"/>" }.joined()
                s += "</customFilters>"
            } else if let t = column.top10 {
                s += "<top10\(t.top ? "" : " top=\"0\"")\(XML.attr("percent", t.percent)) val=\"\(XML.num(t.count))\"\(t.boundary.map { " filterVal=\"\(XML.num($0))\"" } ?? "")/>"
            } else if let d = column.dynamicFilter {
                s += "<dynamicFilter type=\"\(XML.esc(d.kind))\"\(d.value.map { " val=\"\(XML.num($0))\"" } ?? "")\(d.maxValue.map { " maxVal=\"\(XML.num($0))\"" } ?? "")"
                s += XML.attr("valIso", d.valueISO) + XML.attr("maxValIso", d.maxValueISO) + "/>"
            } else if let c = column.colorFilter {
                s += "<colorFilter\(XML.attr("dxfId", c.differentialStyleID))\(c.byCellColor ? "" : " cellColor=\"0\"")/>"
            } else if let i = column.iconFilter {
                s += "<iconFilter iconSet=\"\(XML.esc(i.iconSet))\"\(XML.attr("iconId", i.iconID))/>"
            }
            s += "</filterColumn>"
        }
        if let sort = ws.sortState {
            s += "<sortState ref=\"\(sort.range.a1)\"\(sort.caseSensitive ? " caseSensitive=\"1\"" : "")\(sort.byColumn ? " columnSort=\"1\"" : "")"
            s += sort.conditions.isEmpty ? "/>"
                : ">" + sort.conditions.map { "<sortCondition\($0.descending ? " descending=\"1\"" : "") ref=\"\($0.range.a1)\"/>" }.joined() + "</sortState>"
        }
        return s
    }

    static let ctTable = "application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"
    static let relTable = "/table"

    /// Where a sheet's pivot-table layout parts go, and which cache each reads.
    struct PivotPlan {
        let pivot: PivotTable
        let path: String
        let cacheId: Int
        let cacheDefinitionPath: String
        let relationshipId: String
    }

    /// Where a pivot cache's two parts go, and how the workbook names it.
    struct CachePlan {
        let cache: PivotCache
        let cacheId: Int
        let definitionPath: String
        /// Nil for a cache SwiftSheets generated: it saves no rows and asks for a refresh instead.
        let recordsPath: String?
        let relationshipId: String
    }

    /// Where a sheet's named-table parts go, and what id each gets. Table ids are unique across the workbook.
    struct TablePlan {
        let table: ExcelTable
        let path: String
        let relationshipId: String
        let id: Int
    }

    /// xl/tables/tableN.xml. CT_Table's children in schema order: autoFilter, sortState, tableColumns,
    /// tableStyleInfo, extLst — with the source's own unmodelled attributes and children put back where they were.
    static func tablePartXML(_ plan: TablePlan, sheetName: String, sink: WarningSink) -> String {
        let t = plan.table
        var s = "<table xmlns=\"\(XMLWriter.nsMain)\" id=\"\(plan.id)\" name=\"\(XML.esc(t.name))\" displayName=\"\(XML.esc(t.displayName))\" ref=\"\(t.ref.a1)\""
        if t.headerRowCount != 1 { s += " headerRowCount=\"\(t.headerRowCount)\"" }
        if t.totalsRowCount != 0 { s += " totalsRowCount=\"\(t.totalsRowCount)\"" }
        else if !t.totalsRowShown { s += " totalsRowShown=\"0\"" }
        s += XML.attr("comment", t.comment) + XML.attr("tableType", t.tableType)
        for k in t.otherAttributes.keys.sorted() { s += XML.attr(k, t.otherAttributes[k]) }
        s += ">"
        var generated: [(String, String)] = []
        if let filter = t.autoFilter {
            var view = Sheet(name: sheetName)
            view.filterColumns = t.filterColumns
            let inner = filterChildrenXML(view, sheetName: sheetName, sink: sink)
            generated.append(("autoFilter", "<autoFilter ref=\"\(filter.a1)\"" + (inner.isEmpty ? "/>" : ">" + inner + "</autoFilter>")))
        }
        var columnsXML = "<tableColumns count=\"\(t.columns.count)\">"
        for c in t.columns {
            columnsXML += "<tableColumn id=\"\(c.id)\" name=\"\(XML.esc(OOXMLEscape.escape(c.name)))\""
            columnsXML += XML.attr("totalsRowLabel", c.totalsRowLabel) + XML.attr("totalsRowFunction", c.totalsRowFunction)
            var inner = ""
            if let f = c.calculatedColumnFormula { inner += "<calculatedColumnFormula>\(XML.esc(f))</calculatedColumnFormula>" }
            if let f = c.totalsRowFormula { inner += "<totalsRowFormula>\(XML.esc(f))</totalsRowFormula>" }
            columnsXML += inner.isEmpty ? "/>" : ">" + inner + "</tableColumn>"
        }
        generated.append(("tableColumns", columnsXML + "</tableColumns>"))
        if let info = t.styleInfo {
            generated.append(("tableStyleInfo", "<tableStyleInfo\(XML.attr("name", info.name))"
                + " showFirstColumn=\"\(info.showFirstColumn ? 1 : 0)\" showLastColumn=\"\(info.showLastColumn ? 1 : 0)\""
                + " showRowStripes=\"\(info.showRowStripes ? 1 : 0)\" showColumnStripes=\"\(info.showColumnStripes ? 1 : 0)\"/>"))
        }
        s += XMLWriter.ordered(generated, fragments: t.fragments, order: tableOrder)
        return s + "</table>"
    }

    static let tableOrder = ["autoFilter", "sortState", "tableColumns", "tableStyleInfo", "extLst"]

    /// One `<cfRule>`. CT_CfRule's children in schema order: formula*, colorScale | dataBar | iconSet.
    static func conditionalRuleXML(_ rule: ConditionalFormattingRule, priority: Int, styles: StyleRegistry,
                                   sharedSourceStyles: Set<Int> = []) -> String {
        var s = "<cfRule type=\"\(rule.kind.rawValue)\""
        if let style = rule.style, !style.isEmpty {
            if let source = rule.sourceStyleID, styles.differentialStyles.indices.contains(source),
               styles.differentialStyles[source] != style, !sharedSourceStyles.contains(source) {
                // a source rule whose format was edited, and nothing else points at that entry
                styles.replaceDXF(at: source, with: style)
                s += " dxfId=\"\(source)\""
            } else {
                // an untouched rule keeps its entry; an edited one that shares its entry gets a new entry of its
                // own, so the rules it shared with keep the format they had
                s += " dxfId=\"\(styles.dxfID(style, preferring: rule.sourceStyleID))\""
            }
        }
        s += " priority=\"\(priority)\""
        s += XML.attr("operator", rule.operator?.rawValue)
        s += XML.attr("text", rule.text)
        s += XML.attr("timePeriod", rule.timePeriod)
        s += XML.attr("rank", rule.rank)
        s += XML.attr("bottom", rule.bottom)
        s += XML.attr("percent", rule.percent)
        if rule.kind == .aboveAverage {
            if !rule.aboveAverage { s += " aboveAverage=\"0\"" }
            s += XML.attr("equalAverage", rule.equalAverage)
            s += XML.attr("stdDev", rule.standardDeviation)
        }
        s += XML.attr("stopIfTrue", rule.stopIfTrue)
        var inner = rule.formulas.map { "<formula>\(XML.esc($0))</formula>" }.joined()
        if let scale = rule.colorScale {
            inner += "<colorScale>" + scale.values.map { conditionalValueXML($0) }.joined()
                + scale.colors.map { StyleRegistry.colorXML("color", $0) }.joined() + "</colorScale>"
        }
        if let bar = rule.dataBar {
            inner += "<dataBar\(XML.attr("minLength", bar.minLength))\(XML.attr("maxLength", bar.maxLength))\(bar.showValue ? "" : " showValue=\"0\"")>"
            inner += conditionalValueXML(bar.minimum) + conditionalValueXML(bar.maximum)
            inner += StyleRegistry.colorXML("color", bar.color) + "</dataBar>"
        }
        if let icons = rule.iconSet {
            inner += "<iconSet iconSet=\"\(XML.esc(icons.name))\"\(icons.showValue ? "" : " showValue=\"0\"")\(icons.percent ? "" : " percent=\"0\"")\(XML.attr("reverse", icons.reverse))>"
            inner += icons.values.map { conditionalValueXML($0, includeGTE: true) }.joined() + "</iconSet>"
        }
        return inner.isEmpty ? s + "/>" : s + ">" + inner + "</cfRule>"
    }

    static func conditionalValueXML(_ v: ConditionalValue, includeGTE: Bool = false) -> String {
        var s = "<cfvo type=\"\(v.kind.rawValue)\""
        s += XML.attr("val", v.value)
        if includeGTE, !v.greaterThanOrEqual { s += " gte=\"0\"" }
        return s + "/>"
    }

    static func dateGroupXML(_ g: DateGroup) -> String {
        var s = "<dateGroupItem year=\"\(g.year)\""
        s += XML.attr("month", g.month) + XML.attr("day", g.day)
        s += XML.attr("hour", g.hour) + XML.attr("minute", g.minute) + XML.attr("second", g.second)
        return s + " dateTimeGrouping=\"\(g.grouping.rawValue)\"/>"
    }

    /// Where a sheet's regenerated cell-note parts go. Nil when the sheet has no notes, or when the ones it has
    /// are exactly the ones it was read with — then the source parts are re-packed untouched.
    struct CommentPlan {
        let commentsPath: String
        let vmlPath: String
        let notes: [(ref: CellRef, note: CellNote)]
    }

    /// A freshly generated drawing part for a sheet that had none. A sheet whose source already carries a
    /// drawing needs no plan: its preserved bytes were spliced during planning (spec Appendix B.32).
    struct ImagePlan { var newDrawing: (path: String, xml: String, rels: String)? }

    /// A worksheet part with its rows still to be generated: `head` and `tail` are the small parts of the XML
    /// around `<sheetData>`, and `rows` writes the rows themselves into whatever is given — a buffer feeding the
    /// compressor, or a string for a test to read.
    struct SheetPart {
        let head: String
        let tail: String
        let rows: (PieceBuffer) throws -> Void
        let rels: String?
        let parts: [(path: String, data: Data)]

        /// The whole part as one string.
        var xml: String {
            var out = head
            let buffer = PieceBuffer { out += $0 }
            try? rows(buffer)
            try? buffer.flush()
            return out + tail
        }

        func write(into buffer: PieceBuffer) throws {
            try buffer.write(head)
            try rows(buffer)
            try buffer.write(tail)
        }
    }

    static func sheetXML(_ ws: Sheet, epoch: DateEpoch, styles: StyleRegistry, strings: SharedStringTable, preserve: Bool, isActive: Bool,
                         comments: CommentPlan?, tables: [TablePlan] = [], pivots: [PivotPlan] = [],
                         images: ImagePlan? = nil,
                         sharedSourceStyles: Set<Int> = [], sink: WarningSink) -> (xml: String, rels: String?, parts: [(path: String, data: Data)]) {
        let part = sheetPart(ws, epoch: epoch, styles: styles, strings: strings, preserve: preserve, isActive: isActive, comments: comments,
                             tables: tables, pivots: pivots, images: images, sharedSourceStyles: sharedSourceStyles, sink: sink)
        return (part.xml, part.rels, part.parts)
    }

    /// The marker `ordered` leaves where the rows go.
    static let sheetDataMarker = "\u{0}sheetData\u{0}"

    static func sheetPart(_ ws: Sheet, epoch: DateEpoch, styles: StyleRegistry, strings: SharedStringTable, preserve: Bool, isActive: Bool,
                          comments: CommentPlan?, tables: [TablePlan] = [], pivots: [PivotPlan] = [],
                          images: ImagePlan? = nil,
                          sharedSourceStyles: Set<Int> = [], sink: WarningSink) -> SheetPart {
        let table = ws.table
        // a worksheet is one grid: a canvas carrying several tables (Numbers) keeps only the first one
        if ws.tables.count > 1 {
            sink.add(.dropped, subject: .tables, sheet: ws.name,
                     "\(ws.tables.count - 1) other table(s) not written: a worksheet holds a single grid (write .numbers to keep them)")
        }
        var generated: [(String, String)] = []
        var s = "<sheetPr\(XML.attr("codeName", ws.properties.codeName))\(ws.properties.filterMode.map { " filterMode=\"\($0 ? 1 : 0)\"" } ?? "")>"
        if let tc = ws.properties.tabColor { s += StyleRegistry.colorXML("tabColor", tc) }
        s += "<outlinePr summaryBelow=\"\(ws.properties.summaryBelow ? 1 : 0)\" summaryRight=\"\(ws.properties.summaryRight ? 1 : 0)\"/>"
        s += "<pageSetUpPr\(ws.properties.fitToPage.map { " fitToPage=\"\($0 ? 1 : 0)\"" } ?? "")/></sheetPr>"
        generated.append(("sheetPr", s))
        generated.append(("dimension", "<dimension ref=\"\(table.dimensions)\"/>"))
        s = "<sheetViews><sheetView workbookViewId=\"0\"\(ws.view.showGridLines ? "" : " showGridLines=\"0\"")\(ws.view.zoomScale != 100 ? " zoomScale=\"\(ws.view.zoomScale)\"" : "")\(ws.view.tabSelected || isActive ? " tabSelected=\"1\"" : "")>"
        if let f = ws.freezePanes {
            // Excel omits a zero split and makes the single remaining pane active
            let active = f.col > 0 ? (f.row > 0 ? "bottomRight" : "topRight") : "bottomLeft"
            s += "<pane"
            if f.col > 0 { s += " xSplit=\"\(f.col)\"" }
            if f.row > 0 { s += " ySplit=\"\(f.row)\"" }
            s += " topLeftCell=\"\(f.a1)\" activePane=\"\(active)\" state=\"frozen\"/>"
            if f.col > 0 && f.row > 0 { s += "<selection pane=\"topRight\"/><selection pane=\"bottomLeft\"/>" }
            s += "<selection pane=\"\(active)\" activeCell=\"\(XML.esc(ws.view.activeCell))\" sqref=\"\(XML.esc(ws.view.sqref))\"/>"
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
        // hyperlinks are collected before the rows are written, since the rows are written last
        var hyperlinks: [(String, Hyperlink)] = []
        for (ref, c) in table.cells where c.hyperlink != nil { hyperlinks.append((ref.a1, c.hyperlink!)) }
        hyperlinks.sort { CellRef($0.0)! < CellRef($1.0)! }
        let sheetName = ws.name
        let rows: (PieceBuffer) throws -> Void = { out in
        var s = "<sheetData>"
        // grouped by row, but only the *keys*: grouping the cells themselves would copy every `Cell` (each carries
        // its whole style — 496 bytes), which is half a gigabyte on a million cells
        var byRow: [Int: [CellRef]] = [:]
        for ref in table.cells.keys { byRow[ref.row, default: []].append(ref) }
        let rowNumbers = Set(byRow.keys).union(table.rowDimensions.filter { !$0.value.isDefault }.keys).sorted()
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
            for ref in (byRow[r] ?? []).sorted(by: { $0.col < $1.col }) {
                guard let c = table.cells[ref] else { continue }
                let styleIndex = styles.index(for: c)
                let st = styleIndex != 0 ? " s=\"\(styleIndex)\"" : ""
                let a1 = ref.a1
                switch c.value {
                case nil: s += "<c r=\"\(a1)\"\(st)/>"
                case .formula(let f, let cached)?:
                    var flattened: String?
                    if case .unparsed(_, let dialect) = f, dialect != .xlsx {
                        flattened = "formula in \(dialect.rawValue) dialect could not be translated; cached value written"
                    } else if let fn = f.remoteDataFunction {
                        // the mapping Numbers itself applies on Excel export: a quote function becomes the
                        // value it last fetched, because Excel has no function to recompute one with
                        flattened = "\(fn) fetches live data and Excel has no such function; the cached value is written, the way Numbers itself exports it"
                    }
                    if let flattened {
                        sink.add(.degraded, subject: .formulas, sheet: ws.name, at: ref, flattened)
                        if let cached {
                            let (t, body) = valueXML(cached, epoch: epoch, strings: strings, inline: false)
                            s += "<c r=\"\(a1)\"\(st)\(t)>\(body)</c>"
                        } else { s += "<c r=\"\(a1)\"\(st)/>" }
                        continue
                    }
                    var t = "", cv = ""
                    if let cached { (t, cv) = valueXML(cached, epoch: epoch, strings: strings, inline: true) }
                    // an array formula fills a range from one cell; without t="array" and the range Excel reads it
                    // as an ordinary formula, which computes something else
                    let array = table.arrayFormulas[ref].map { " t=\"array\" ref=\"\($0.a1)\"" } ?? ""
                    s += "<c r=\"\(a1)\"\(st)\(t)><f\(array)>\(XML.esc(f.rendered(as: .xlsx)))</f>\(cv)</c>"
                case let v?:
                    let (t, body) = valueXML(v, epoch: epoch, strings: strings, inline: false)
                    s += "<c r=\"\(a1)\"\(st)\(t)>\(body)</c>"
                }
            }
            s += "</row>"
            if s.utf8.count >= PieceBuffer.pieceSize { try out.write(s); s = "" }
        }
        try out.write(s + "</sheetData>")
        }
        generated.append(("sheetData", sheetDataMarker))
        if !ws.protection.isDefault {
            let p = ws.protection
            var x = "<sheetProtection"
            x += XML.attr("algorithmName", p.algorithmName) + XML.attr("hashValue", p.hashValue)
            x += XML.attr("saltValue", p.saltValue) + XML.attr("spinCount", p.spinCount)
            x += XML.attr("password", p.passwordHash)
            x += XML.attr("sheet", p.enabled)
            // the file says what is forbidden, so each "allows" is written inverted — and only when it differs
            // from the format's own default (formatting and friends forbidden, selection allowed)
            x += XML.attr("objects", !p.allowsEditingObjects) + XML.attr("scenarios", !p.allowsEditingScenarios)
            if p.allowsFormattingCells { x += " formatCells=\"0\"" }
            if p.allowsFormattingColumns { x += " formatColumns=\"0\"" }
            if p.allowsFormattingRows { x += " formatRows=\"0\"" }
            if p.allowsInsertingColumns { x += " insertColumns=\"0\"" }
            if p.allowsInsertingRows { x += " insertRows=\"0\"" }
            if p.allowsInsertingHyperlinks { x += " insertHyperlinks=\"0\"" }
            if p.allowsDeletingColumns { x += " deleteColumns=\"0\"" }
            if p.allowsDeletingRows { x += " deleteRows=\"0\"" }
            x += XML.attr("selectLockedCells", !p.allowsSelectingLockedCells)
            if p.allowsSorting { x += " sort=\"0\"" }
            if p.allowsFiltering { x += " autoFilter=\"0\"" }
            if p.allowsPivotTables { x += " pivotTables=\"0\"" }
            x += XML.attr("selectUnlockedCells", !p.allowsSelectingUnlockedCells)
            generated.append(("sheetProtection", x + "/>"))
        }
        if !ws.protectedRanges.isEmpty {
            var x = "<protectedRanges>"
            for r in ws.protectedRanges {
                x += "<protectedRange"
                x += XML.attr("password", r.passwordHash) + XML.attr("algorithmName", r.algorithmName)
                x += XML.attr("hashValue", r.hashValue) + XML.attr("saltValue", r.saltValue) + XML.attr("spinCount", r.spinCount)
                x += " sqref=\"\(r.ranges.description)\" name=\"\(XML.esc(r.name))\""
                x += XML.attr("securityDescriptor", r.securityDescriptor) + "/>"
            }
            generated.append(("protectedRanges", x + "</protectedRanges>"))
        }
        if !ws.scenarios.isEmpty {
            let list = ws.scenarios
            var x = "<scenarios"
            x += XML.attr("current", list.current) + XML.attr("show", list.shown)
            x += " sqref=\"\(list.touchedCells.description)\">"
            for sc in list.scenarios {
                x += "<scenario name=\"\(XML.esc(sc.name))\"\(XML.attr("locked", sc.locked))\(XML.attr("hidden", sc.hidden))"
                x += " count=\"\(sc.cells.count)\"\(XML.attr("user", sc.user))\(XML.attr("comment", sc.comment))>"
                for c in sc.cells {
                    x += "<inputCells r=\"\(c.ref.a1)\"\(XML.attr("deleted", c.deleted))\(XML.attr("undone", c.undone))"
                    x += " val=\"\(XML.esc(c.value))\"\(XML.attr("numFmtId", c.numberFormatID))/>"
                }
                x += "</scenario>"
            }
            generated.append(("scenarios", x + "</scenarios>"))
        }
        let fragments = preserve ? ws.preserved.fragments : []
        // the source's own <autoFilter> is re-emitted verbatim only when it uses a filter kind the model cannot
        // say (colour, icon, dynamic, top 10, date groups); otherwise it is regenerated from the model
        let hasFilterFragment = fragments.contains { $0.element == "autoFilter" }
        if let af = ws.autoFilter, !hasFilterFragment {
            var filter = "<autoFilter ref=\"\(af.a1)\""
            let inner = filterChildrenXML(ws, sheetName: ws.name, sink: sink)
            filter += inner.isEmpty ? "/>" : ">" + inner + "</autoFilter>"
            generated.append(("autoFilter", filter))
        }
        if !table.merges.isEmpty {
            generated.append(("mergeCells", "<mergeCells count=\"\(table.merges.count)\">" + table.merges.map { "<mergeCell ref=\"\($0.a1)\"/>" }.joined() + "</mergeCells>"))
        }
        // conditional formatting: one element per block, and priorities renumbered 1…n over the whole sheet
        // (Excel wants them distinct, and only their order carries meaning)
        if !ws.conditionalFormatting.isEmpty {
            if fragments.contains(where: { $0.element == "conditionalFormatting" }) {
                sink.add(.degraded, subject: .formatting, sheet: ws.name,
                         "\(ws.conditionalFormatting.count) conditional format(s) not written: this sheet was read from a file whose own rules the model could not say, and those are written back unchanged")
            } else {
                var order: [(block: Int, rule: Int)] = []
                for (b, block) in ws.conditionalFormatting.enumerated() {
                    for (r, _) in block.rules.enumerated() { order.append((b, r)) }
                }
                order.sort { a, b in
                    let pa = ws.conditionalFormatting[a.block].rules[a.rule].priority
                    let pb = ws.conditionalFormatting[b.block].rules[b.rule].priority
                    return pa != pb ? pa < pb : (a.block, a.rule) < (b.block, b.rule)
                }
                var renumbered: [String: Int] = [:]
                for (i, key) in order.enumerated() { renumbered["\(key.block).\(key.rule)"] = i + 1 }
                for (b, block) in ws.conditionalFormatting.enumerated() {
                    var x = "<conditionalFormatting sqref=\"\(block.ranges.description)\"\(XML.attr("pivot", block.pivot))>"
                    for (r, rule) in block.rules.enumerated() {
                        x += conditionalRuleXML(rule, priority: renumbered["\(b).\(r)"] ?? rule.priority, styles: styles,
                                                sharedSourceStyles: sharedSourceStyles)
                    }
                    generated.append(("conditionalFormatting", x + "</conditionalFormatting>"))
                }
            }
        }
        // data validation is write-side only (spec B.13): a source file's own block is preserved verbatim, and the
        // schema allows a single <dataValidations>, so a sheet that has both keeps the file's and says what it lost
        if !ws.dataValidations.isEmpty {
            if fragments.contains(where: { $0.element == "dataValidations" }) {
                sink.add(.degraded, subject: .formatting, sheet: ws.name,
                         "\(ws.dataValidations.count) data validation(s) not written: this sheet was read from a file that carries its own, which is written back unchanged")
            } else {
                let rules = ws.dataValidations.map(dataValidationXML).joined()
                generated.append(("dataValidations", "<dataValidations count=\"\(ws.dataValidations.count)\">" + rules + "</dataValidations>"))
            }
        }
        // sheet relationships: preserved ones keep their ids; hyperlinks and regenerated note parts follow them.
        // A regenerated comments part replaces the source's, so the source's own two relationships step aside.
        var preservedRels = preserve ? ws.preserved.relationships : []
        var noteFragments = fragments
        if comments != nil || (preserve && !ws.preserved.comments.isEmpty && ws.notes.isEmpty) {
            preservedRels.removeAll { $0.type.hasSuffix(CommentParts.relationshipType) || $0.type.hasSuffix(CommentParts.vmlRelationshipType) }
            noteFragments.removeAll { $0.element == "legacyDrawing" }
        }
        var extraParts: [(path: String, data: Data)] = []
        var rels: String?
        var relXML = "<Relationships xmlns=\"\(XMLWriter.nsPkgRel)\">" + preservedRels.map(relationshipXML).joined()
        var next = (preservedRels.compactMap(\.number).max() ?? 0) + 1
        var usedRelIDs = Set(preservedRels.map(\.id))
        func freshRelID() -> String {
            while usedRelIDs.contains("rId\(next)") { next += 1 }
            defer { next += 1 }
            usedRelIDs.insert("rId\(next)")
            return "rId\(next)"
        }
        if !hyperlinks.isEmpty {
            s = "<hyperlinks>"
            for (a1, h) in hyperlinks {
                if h.isInternal { s += "<hyperlink ref=\"\(a1)\" location=\"\(XML.esc(h.target))\"\(XML.attr("display", h.display))\(XML.attr("tooltip", h.tooltip))/>" }
                else {
                    let id = freshRelID()
                    s += "<hyperlink ref=\"\(a1)\" r:id=\"\(id)\"\(XML.attr("display", h.display))\(XML.attr("tooltip", h.tooltip))/>"
                    relXML += "<Relationship Id=\"\(id)\" Type=\"\(XMLWriter.nsRel)/hyperlink\" Target=\"\(XML.esc(h.target))\" TargetMode=\"External\"/>"
                }
            }
            generated.append(("hyperlinks", s + "</hyperlinks>"))
        }
        if !tables.isEmpty {
            let dir = ws.preserved.partPath.map { ($0 as NSString).deletingLastPathComponent } ?? "xl/worksheets"
            var parts = "<tableParts count=\"\(tables.count)\">"
            for plan in tables {
                var id = plan.relationshipId
                if id.isEmpty || usedRelIDs.contains(id) { id = freshRelID() } else { usedRelIDs.insert(id) }
                parts += "<tablePart r:id=\"\(id)\"/>"
                relXML += "<Relationship Id=\"\(id)\" Type=\"\(XMLWriter.nsRel)\(relTable)\" Target=\"\(XML.esc(relativeTarget(plan.path, from: dir)))\"/>"
                extraParts.append((plan.path, Data((XMLWriter.header + tablePartXML(plan, sheetName: ws.name, sink: sink)).utf8)))
            }
            generated.append(("tableParts", parts + "</tableParts>"))
        }
        for plan in pivots {
            let dir = ws.preserved.partPath.map { ($0 as NSString).deletingLastPathComponent } ?? "xl/worksheets"
            var id = plan.relationshipId
            if id.isEmpty || usedRelIDs.contains(id) { id = freshRelID() } else { usedRelIDs.insert(id) }
            relXML += "<Relationship Id=\"\(id)\" Type=\"\(XMLWriter.nsRel)\(PivotParts.relTable)\" Target=\"\(XML.esc(relativeTarget(plan.path, from: dir)))\"/>"
            extraParts.append((plan.path, Data((XMLWriter.header + PivotParts.tableXML(plan.pivot, cacheId: plan.cacheId)).utf8)))
            // the layout part points back at the cache definition through a relationship of its own
            let pivotDir = (plan.path as NSString).deletingLastPathComponent
            let cacheRels = XMLWriter.header + "<Relationships xmlns=\"\(XMLWriter.nsPkgRel)\">"
                + "<Relationship Id=\"rId1\" Type=\"\(XMLWriter.nsRel)\(PivotParts.relCacheDefinition)\" Target=\"\(XML.esc(relativeTarget(plan.cacheDefinitionPath, from: pivotDir)))\"/></Relationships>"
            extraParts.append((WorkbookReader.relsPath(of: plan.path), Data(cacheRels.utf8)))
        }
        if let plan = comments {
            let dir = (ws.preserved.partPath.map { ($0 as NSString).deletingLastPathComponent } ?? "xl/worksheets")
            let commentsID = freshRelID(), vmlID = freshRelID()
            relXML += "<Relationship Id=\"\(commentsID)\" Type=\"\(XMLWriter.nsRel)\(CommentParts.relationshipType)\" Target=\"\(XML.esc(relativeTarget(plan.commentsPath, from: dir)))\"/>"
            relXML += "<Relationship Id=\"\(vmlID)\" Type=\"\(XMLWriter.nsRel)\(CommentParts.vmlRelationshipType)\" Target=\"\(XML.esc(relativeTarget(plan.vmlPath, from: dir)))\"/>"
            generated.append(("legacyDrawing", "<legacyDrawing r:id=\"\(vmlID)\"/>"))
            extraParts.append((plan.commentsPath, Data((XMLWriter.header + CommentParts.commentsXML(plan.notes)).utf8)))
            extraParts.append((plan.vmlPath, Data(CommentParts.vmlXML(plan.notes).utf8)))
        }
        if let plan = images?.newDrawing {
            let dir = (ws.preserved.partPath.map { ($0 as NSString).deletingLastPathComponent } ?? "xl/worksheets")
            let id = freshRelID()
            relXML += "<Relationship Id=\"\(id)\" Type=\"\(XMLWriter.nsRel)\(DrawingParts.relationshipType)\" Target=\"\(XML.esc(relativeTarget(plan.path, from: dir)))\"/>"
            generated.append(("drawing", "<drawing r:id=\"\(id)\"/>"))
            extraParts.append((plan.path, Data((XMLWriter.header + plan.xml).utf8)))
            extraParts.append((WorkbookReader.relsPath(of: plan.path), Data(plan.rels.utf8)))
        }
        if !preservedRels.isEmpty || relXML.contains("/hyperlink") || comments != nil || !tables.isEmpty || !pivots.isEmpty || images?.newDrawing != nil {
            rels = relXML + "</Relationships>"
        }
        let po = ws.printOptions
        if po != PrintOptions() {
            generated.append(("printOptions", "<printOptions\(XML.attr("horizontalCentered", po.horizontalCentered))\(XML.attr("verticalCentered", po.verticalCentered))\(XML.attr("headings", po.headings))\(XML.attr("gridLines", po.gridLines))/>"))
        }
        let m = ws.pageMargins
        generated.append(("pageMargins", "<pageMargins left=\"\(XML.num(m.left))\" right=\"\(XML.num(m.right))\" top=\"\(XML.num(m.top))\" bottom=\"\(XML.num(m.bottom))\" header=\"\(XML.num(m.header))\" footer=\"\(XML.num(m.footer))\"/>"))
        let p = ws.pageSetup
        // the printer-settings part travels as an opaque part; `r:id` is the only thing that ties it to the sheet
        let printerSettings = preserve ? ws.preserved.pageSetupRelationshipId.flatMap { id in
            preservedRels.contains { $0.id == id } ? id : nil
        } : nil
        if p != PageSetup() || printerSettings != nil {
            generated.append(("pageSetup", "<pageSetup\(XML.attr("orientation", p.orientation?.rawValue))\(XML.attr("paperSize", p.paperSize))\(XML.attr("scale", p.scale))\(XML.attr("fitToWidth", p.fitToWidth))\(XML.attr("fitToHeight", p.fitToHeight))\(XML.attr("firstPageNumber", p.firstPageNumber))\(p.useFirstPageNumber.map { " useFirstPageNumber=\"\($0 ? 1 : 0)\"" } ?? "")\(printerSettings.map { " r:id=\"\($0)\"" } ?? "")/>"))
        }
        let hf = ws.headerFooter
        if !hf.isEmpty {
            s = "<headerFooter\(XML.attr("differentOddEven", hf.differentOddEven))\(XML.attr("differentFirst", hf.differentFirst))"
            if !hf.scaleWithDoc { s += " scaleWithDoc=\"0\"" }
            if !hf.alignWithMargins { s += " alignWithMargins=\"0\"" }
            s += ">"
            for (tag, text) in [("oddHeader", hf.oddHeader), ("oddFooter", hf.oddFooter), ("evenHeader", hf.evenHeader),
                                ("evenFooter", hf.evenFooter), ("firstHeader", hf.firstHeader), ("firstFooter", hf.firstFooter)] {
                if let text { s += "<\(tag)>\(XML.esc(text))</\(tag)>" }
            }
            generated.append(("headerFooter", s + "</headerFooter>"))
        }
        for (element, breaks) in [("rowBreaks", ws.rowBreaks), ("colBreaks", ws.columnBreaks)] where !breaks.isEmpty {
            let max = element == "rowBreaks" ? CellRef.maxCol : CellRef.maxRow
            generated.append((element, "<\(element) count=\"\(breaks.count)\" manualBreakCount=\"\(breaks.count)\">"
                + breaks.sorted().map { "<brk id=\"\($0)\" max=\"\(max)\" man=\"1\"/>" }.joined() + "</\(element)>"))
        }
        var xml = "<worksheet" + XMLWriter.rootAttributes(preserve ? ws.preserved.rootAttributes : [:], defaults: ["xmlns": XMLWriter.nsMain, "xmlns:r": XMLWriter.nsRel]) + ">"
        xml += XMLWriter.ordered(generated, fragments: noteFragments, order: worksheetOrder)
        xml += "</worksheet>"
        _ = sheetName
        guard let marker = xml.range(of: sheetDataMarker) else { return SheetPart(head: xml, tail: "", rows: { _ in }, rels: rels, parts: extraParts) }
        return SheetPart(head: String(xml[..<marker.lowerBound]), tail: String(xml[marker.upperBound...]), rows: rows, rels: rels, parts: extraParts)
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
