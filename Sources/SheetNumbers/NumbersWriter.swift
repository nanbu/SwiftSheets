import Foundation
import SheetCore

/// Template-patch writer (spec §11.1, Appendix B.8): the empty document is loaded, its one sheet / table subgraph is
/// patched (or cloned for further sheets and tables), cells are packed into tiles, strings into the string list.
/// Every object the model does not touch stays as the template had it. Formulas are written as their cached value
/// with a `degraded` warning (no formula archives — B.8).
struct NumbersWriter {
    static let tileSize = 256
    static let preBNCBytes = Data("🤠".utf8)   // what Numbers itself writes in the legacy fields
    static let defaultRowHeight = 20.0
    static let defaultColumnWidth = 98.0
    static let tableGap = 80.0
    /// Whether a pivot table is written as a Numbers pivot (Appendix B.19). **Off**: the archives are built and
    /// the summary is computed, but Numbers 15.3.1 still opens the result with the summary's cells in error, so
    /// what a reader would get is a broken pivot rather than none. Until the judge passes it, a pivot is reported
    /// as dropped, as it was before — this project does not let a broken document through quietly.
    static let writesPivotTables = false

    let doc: NumbersDocument
    let workbook: Workbook
    let options: WriteOptions
    var warnings: [ConversionWarning] = []
    /// The template's sheet, table info and table model.
    private let templateSheet: Int
    private let templateTableInfo: Int
    private let templateTableModel: Int
    /// Identifiers of objects cloned per table; kept so a sheet clone knows what belongs to its table.
    private var calcEngineID: Int
    /// "Sheet::Table" → the identifier a cross-table reference names it by.
    private var tableUUIDs: [String: ProtoMessage] = [:]
    /// Author name → its archive, so two notes by the same person share one author.
    private var authorIDs: [String: Int] = [:]
    /// Sheet name → the table info of its first table, which is the table a pivot on that sheet's range names as
    /// its source (Appendix B.19).
    private var firstTableInfo: [String: Int?] = [:]
    /// Component entries waiting to go into the package metadata. Registering them one at a time meant walking
    /// the whole metadata once per object — with four sheets that was most of the time the write took.
    private var pendingComponents: [(new: Int, like: Int?, locator: String)] = []

    init(workbook: Workbook, options: WriteOptions) throws {
        self.workbook = workbook
        self.options = options
        let d = try NumbersDocument(data: try Data(contentsOf: NumbersCodec.templateURL))
        doc = d
        guard let document = d.object(NumbersDocument.documentID), let sheet = document.references("sheets").first(where: { d.typeName($0) == "TN.SheetArchive" }),
              let info = d.object(sheet)?.references("drawable_infos").first(where: { d.typeName($0) == "TST.TableInfoArchive" }),
              let model = d.object(info)?.reference("tableModel"), let engine = d.identifiers(ofType: "TSCE.CalculationEngineArchive").first else {
            throw SheetError.malformedPart(path: "empty.numbers", detail: "the template has no sheet / table")
        }
        templateSheet = sheet; templateTableInfo = info; templateTableModel = model; calcEngineID = engine
    }

    mutating func write() throws -> Data {
        guard !workbook.sheets.isEmpty else { throw SheetError.invalidWorkbook("a workbook needs at least one sheet") }
        if let src = workbook.preserved.sourceFormat, src != .numbers, !workbook.preserved.opaqueParts.isEmpty {
            warnings.append(ConversionWarning(.dropped, message: "\(workbook.preserved.opaqueParts.count) part(s) preserved from the \(src.rawValue) file cannot be carried into Numbers"))
        }
        if !workbook.definedNames.isEmpty {
            warnings.append(ConversionWarning(.dropped, subject: .formulas, message: "\(workbook.definedNames.count) defined name(s) dropped: Numbers has no defined names"))
        }
        if workbook.protection != WorkbookProtection() {
            warnings.append(ConversionWarning(.dropped, subject: .other, message: "workbook protection is dropped: Numbers locks a document with a password, which this writer does not set"))
        }
        if !workbook.customProperties.isEmpty {
            warnings.append(ConversionWarning(.dropped, subject: .other, message: "\(workbook.customProperties.count) custom document propert(ies) dropped: Numbers has no free-form document fields"))
        }
        // the date origin: Numbers keeps it on the calculation engine, as the reader expects to find it
        if let engine = doc.identifiers(ofType: "TSCE.CalculationEngineArchive").first {
            doc.update(engine) { $0.set("base_date_1904", bool: workbook.epoch == .mac1904) }
        } else if workbook.epoch == .mac1904 {
            warnings.append(ConversionWarning(.dropped, message: "the 1904 date origin is dropped: the template has no calculation engine to record it on"))
        }
        // Every sheet is copied before any of them is patched. A sheet cloned later would inherit whatever the
        // template sheet had grown by then — the second table of the first sheet, for instance, which Numbers finds
        // and cannot make sense of (Appendix B.18).
        var sheetIDs: [Int] = [templateSheet]
        for _ in 1..<workbook.sheets.count { sheetIDs.append(try cloneSheet()) }
        // …and every table before any cell is written, so that a formula on one table can name another: a
        // cross-table reference carries the target's UUID, which does not exist until the table does (B.18).
        var tableInfos: [Int: [Int]] = [:]
        for (i, sheet) in workbook.sheets.enumerated() {
            let sid = sheetIDs[i]
            var infos = doc.object(sid)?.references("drawable_infos").filter { doc.typeName($0) == "TST.TableInfoArchive" } ?? []
            // …plus two per pivot table: a Numbers pivot is a summary table and a copy of the rows it summarises
            // (Appendix B.19). They are cloned here, with the sheet's own tables, so that every copy comes from
            // the template's untouched table rather than from one already filled in.
            let wanted = Swift.max(1, sheet.tables.count)
                + (NumbersWriter.writesPivotTables ? 2 * sheet.pivotTables.count : 0)
            while infos.count < wanted { infos.append(try cloneTable(from: infos[0], intoSheet: sid)) }
            tableInfos[sid] = infos
            firstTableInfo[sheet.name] = infos.first
            let tables = sheet.tables.isEmpty ? [Table()] : sheet.tables
            for (t, table) in tables.enumerated() {
                guard let model = doc.object(infos[t])?.reference("tableModel"),
                      let uuid = tableReferenceUUID(ofTableModel: model) else { continue }
                tableUUIDs[sheet.name + "::" + (table.name ?? "Table \(t + 1)")] = uuid
            }
        }
        for (i, sheet) in workbook.sheets.enumerated() {
            let sid = sheetIDs[i]
            doc.update(sid) { $0.set("name", string: sheet.name) }
            if sheet.state != .visible { warnings.append(ConversionWarning(.degraded, sheet: sheet.name, message: "Numbers has no hidden sheets; the sheet is visible")) }
            if !sheet.dataValidations.isEmpty || sheet.hasUnmodelledValidations {
                warnings.append(ConversionWarning(.dropped, subject: .formatting, sheet: sheet.name, message: "data validation dropped: Numbers rules are not written"))
            }
            if sheet.hasUnmodelledConditionalFormats {
                warnings.append(ConversionWarning(.dropped, subject: .formatting, sheet: sheet.name,
                                                  message: "a conditional format the model could not fully read is dropped: its own block cannot be carried into Numbers"))
            }
            if sheet.tables.count > 1, !sheet.conditionalFormatting.isEmpty {
                warnings.append(ConversionWarning(.degraded, subject: .formatting, sheet: sheet.name,
                                                  message: "the sheet's conditional formats are written onto its first table: the model keeps them per sheet, Numbers per table"))
            }
            if !sheet.excelTables.isEmpty {
                warnings.append(ConversionWarning(.dropped, subject: .tables, sheet: sheet.name, message: "\(sheet.excelTables.count) named table(s) dropped: every Numbers table is named, but its own header rows are not this frame"))
            }
            // the rest of what a sheet can say and a Numbers table cannot. None of it is dropped in silence.
            if sheet.autoFilter != nil || !sheet.filterColumns.isEmpty || sheet.sortState != nil {
                warnings.append(ConversionWarning(.dropped, subject: .formatting, sheet: sheet.name, message: "the auto-filter and its sort are dropped: a Numbers table filters and sorts through its own rules, which are not written"))
            }
            if sheet.protection.enabled || !sheet.protectedRanges.isEmpty {
                warnings.append(ConversionWarning(.dropped, subject: .other, sheet: sheet.name, message: "sheet protection is dropped: Numbers protects a whole document, not a sheet"))
            }
            if !sheet.scenarios.isEmpty {
                warnings.append(ConversionWarning(.dropped, subject: .other, sheet: sheet.name, message: "\(sheet.scenarios.count) scenario(s) dropped: Numbers has no scenarios"))
            }
            if !sheet.headerFooter.isEmpty || sheet.pageSetup != PageSetup() || !sheet.printArea.isEmpty
                || sheet.printTitleRows != nil || sheet.printTitleColumns != nil || !sheet.rowBreaks.isEmpty || !sheet.columnBreaks.isEmpty {
                warnings.append(ConversionWarning(.dropped, subject: .formatting, sheet: sheet.name, message: "the print setup (headers, page breaks, print area, orientation) is dropped: Numbers prints a canvas, not a page grid"))
            }
            if !sheet.definedNames.isEmpty {
                warnings.append(ConversionWarning(.dropped, subject: .formulas, sheet: sheet.name, message: "\(sheet.definedNames.count) sheet-scoped name(s) dropped: Numbers has no defined names"))
            }
            if sheet.tabColor != nil {
                warnings.append(ConversionWarning(.dropped, subject: .formatting, sheet: sheet.name, message: "the tab colour is dropped: Numbers tabs have no colour"))
            }
            if sheet.tables.contains(where: { table in table.rowDimensions.values.contains { $0.outlineLevel > 0 } || table.columnDimensions.values.contains { $0.outlineLevel > 0 } }) {
                warnings.append(ConversionWarning(.dropped, subject: .formatting, sheet: sheet.name, message: "row / column grouping is dropped: Numbers groups by category, not by outline level"))
            }
            let infos = tableInfos[sid] ?? []
            let tables = sheet.tables.isEmpty ? [Table()] : sheet.tables
            var y = 0.0
            for (t, table) in tables.enumerated() {
                let info = infos[t]
                let name = table.name ?? "Table \(t + 1)"
                let size = try patch(tableInfo: info, with: table, name: name, sheetName: sheet.name,
                                     conditionalFormats: t == 0 ? sheet.conditionalFormatting : [])
                doc.update(info) { m in
                    var d = m.message("super") ?? ProtoMessage(typeName: "TSD.DrawableArchive")
                    var g = d.message("geometry") ?? ProtoMessage(typeName: "TSD.GeometryArchive")
                    var p = ProtoMessage(typeName: "TSP.Point"); p.set("x", float: 0); p.set("y", float: Float(y))
                    var s = ProtoMessage(typeName: "TSP.Size"); s.set("width", float: Float(size.width)); s.set("height", float: Float(size.height))
                    g.set("position", message: p); g.set("size", message: s)
                    d.set("geometry", message: g)
                    m.set("super", message: d)
                }
                y += size.height + NumbersWriter.tableGap
            }
            // the pivots, each on the pair of tables cloned for it above
            var spare = tables.count
            if !sheet.pivotTables.isEmpty, !NumbersWriter.writesPivotTables {
                warnings.append(ConversionWarning(.dropped, subject: .objects, sheet: sheet.name,
                                                  message: "\(sheet.pivotTables.count) pivot table(s) dropped: Numbers pivot tables are not written"))
            }
            for pivot in sheet.pivotTables where NumbersWriter.writesPivotTables {
                let size = try writePivot(pivot, summaryInfo: infos[spare], sourceInfo: infos[spare + 1],
                                          onSheet: sid, sheetName: sheet.name, at: y)
                spare += 2
                y += size.height + NumbersWriter.tableGap
            }
            if sheet.freezePanes != nil, tables.first?.nextAppendRow ?? 0 > 0 {
                // header rows / columns are Numbers' frozen panes
                let fp = sheet.freezePanes!
                doc.update(doc.object(infos[0])!.reference("tableModel")!) { m in
                    m.set("number_of_header_rows", int: fp.row); m.set("number_of_header_columns", int: fp.col)
                    m.set("header_rows_frozen", bool: fp.row > 0); m.set("header_columns_frozen", bool: fp.col > 0)
                }
            }
        }
        flushComponents()
        doc.update(NumbersDocument.documentID) { $0.set("sheets", references: sheetIDs) }
        doc.setBlob("Metadata/DocumentIdentifier", Data(UUID().uuidString.utf8))
        return doc.encoded()
    }

    // MARK: - Cloning (further sheets / tables)

    /// Types that belong to one table / sheet and are copied; everything else (styles, presets, the stylesheet) is shared.
    static let clonedTypes: Set<String> = [
        "TN.SheetArchive", "TSD.GuideStorageArchive", "TSWP.StorageArchive", "TST.TableInfoArchive", "TST.TableModelArchive", "TST.SummaryModelArchive",
        "TST.CategoryOrderArchive", "TSA.StandinCaptionArchive", "TSA.CaptionInfoArchive", "TSA.CaptionPlacementArchive", "TST.HeaderStorageBucket", "TST.Tile",
        "TST.TableDataList", "TST.HiddenStateFormulaOwnerArchive", "TST.FilterSetArchive", "TST.TrackedReferenceStoreArchive", "TST.ColumnRowUIDMapArchive",
        "TST.StrokeSidecarArchive", "TST.CategoryOwnerRefArchive", "TST.GroupByArchive", "TST.MergeRegionMapArchive", "TST.PivotOrderArchive",
    ]

    /// Deep-copies the subgraph under `root` (types in `clonedTypes` only), gives every copy a new id, rewrites the
    /// references between copies, regenerates every UUID consistently, registers component metadata and the
    /// calculation-engine owner entries. Returns old id → new id.
    private mutating func clone(root: Int, skipping: Set<Int> = []) throws -> [Int: Int] {
        var toClone: [Int] = []
        var seen = Set<Int>()
        func visit(_ id: Int) {
            guard !seen.contains(id), !skipping.contains(id), let t = doc.typeName(id), NumbersWriter.clonedTypes.contains(t) else { return }
            seen.insert(id); toClone.append(id)
            for r in doc.object(id)?.allReferences() ?? [] { visit(r) }
        }
        visit(root)
        var map: [Int: Int] = [:]
        var uuidMap: [String: ProtoMessage] = [:]
        // the table's two calculation-engine owners travel with it
        var owners: [Int] = []
        if let tableModel = toClone.first(where: { doc.typeName($0) == "TST.TableModelArchive" }), let info = toClone.first(where: { doc.typeName($0) == "TST.TableInfoArchive" }) {
            let haunted = NumbersUUID.hex(doc.object(tableModel)?.message("haunted_owner")?.message("owner_uid"))
            for fid in doc.identifiers(ofType: "TSCE.FormulaOwnerDependenciesArchive") {
                guard let f = doc.object(fid) else { continue }
                if f.reference("formula_owner") == info || (haunted != nil && NumbersUUID.hex(f.message("formula_owner_uid")) == haunted) { owners.append(fid) }
            }
        }
        for id in toClone + owners {
            guard let (path, _) = doc.locations[id], let obj = doc.object(id) else { continue }
            let file = path.contains("/Tables/") ? path.replacingOccurrences(of: "\\d+(-\\d+)?\\.iwa$", with: "{id}.iwa", options: .regularExpression).replacingOccurrences(of: ".iwa{id}", with: "-{id}") : path
            let target = file.hasSuffix("{id}.iwa") ? file : (path.contains("/Tables/") ? path.replacingOccurrences(of: ".iwa", with: "-{id}.iwa") : path)
            let new = try doc.add(obj, file: target)
            map[id] = new
            if path.contains("/Tables/") { registerComponent(new, like: id) }
        }
        // rewrite references and UUIDs in every copy
        for (old, new) in map {
            guard var obj = doc.object(new) else { continue }
            obj = obj.remappingReferences(map)
            obj = NumbersWriter.remappingUUIDs(obj, &uuidMap)
            if obj.typeName == "TST.TableModelArchive" { obj.set("table_id", string: NumbersUUID.random().string) }
            doc.replace(new, with: obj)
            _ = old
        }
        // owner id map entries for the cloned calculation-engine owners
        var nextOwner = (doc.object(calcEngineID)?.message("dependency_tracker")?.message("owner_id_map")?.messages("map_entry").compactMap { $0.int("internal_owner_id") }.max() ?? 0) + 1
        var newEntries: [ProtoMessage] = []
        for old in owners {
            guard let new = map[old], var f = doc.object(new) else { continue }
            f.set("internal_formula_owner_id", int: nextOwner)
            doc.replace(new, with: f)
            var entry = ProtoMessage(typeName: "TSCE.OwnerIDMapArchive.OwnerIDMapArchiveEntry")
            entry.set("internal_owner_id", int: nextOwner)
            if let uuid = f.message("formula_owner_uid"), let hex = NumbersUUID.hex(uuid) {
                var cf = ProtoMessage(typeName: "TSP.CFUUIDArchive")
                let lo = uuid.uint("lower") ?? 0, hi = uuid.uint("upper") ?? 0
                cf.set("uuid_w0", uint: lo & 0xFFFF_FFFF); cf.set("uuid_w1", uint: lo >> 32); cf.set("uuid_w2", uint: hi & 0xFFFF_FFFF); cf.set("uuid_w3", uint: hi >> 32)
                entry.set("owner_id", message: cf)
                _ = hex
            }
            newEntries.append(entry)
            nextOwner += 1
        }
        if !newEntries.isEmpty {
            let ownerRefs = owners.compactMap { map[$0] }
            doc.update(calcEngineID) { ce in
                var tracker = ce.message("dependency_tracker") ?? ProtoMessage(typeName: "TSCE.DependencyTrackerArchive")
                var omap = tracker.message("owner_id_map") ?? ProtoMessage(typeName: "TSCE.OwnerIDMapArchive")
                for e in newEntries { omap.append("map_entry", message: e) }
                tracker.set("owner_id_map", message: omap)
                for r in ownerRefs { tracker.append("formula_owner_dependencies", reference: r) }
                ce.set("dependency_tracker", message: tracker)
            }
        }
        // component external references and object→UUID entries that named an original now also name its copy
        duplicateComponentEntries(map)
        return map
    }

    /// Every `TSP.UUID` / `TSP.CFUUIDArchive` inside the message replaced consistently (same old value → same new value).
    private static func remappingUUIDs(_ m: ProtoMessage, _ map: inout [String: ProtoMessage]) -> ProtoMessage {
        guard let t = m.typeName else { return m }
        var copy = m
        for i in copy.fields.indices {
            guard case .bytes(let d) = copy.fields[i].value, let info = NumbersSchema.shared.field(t, number: copy.fields[i].number), info.type == "message", let child = info.typeName else { continue }
            guard let sub = try? ProtoMessage(decoding: d, typeName: child) else { continue }
            if child == "TSP.UUID" || child == "TSP.CFUUIDArchive" {
                guard let hex = NumbersUUID.hex(sub) else { continue }
                if map[hex] == nil { let fresh = NumbersUUID.random(); map[hex] = child == "TSP.UUID" ? fresh.uuid : fresh.cfuuid; map[hex + "#other"] = child == "TSP.UUID" ? fresh.cfuuid : fresh.uuid }
                let replacement = child == "TSP.UUID" ? (map[hex]!.typeName == "TSP.UUID" ? map[hex]! : map[hex + "#other"]!) : (map[hex]!.typeName == "TSP.CFUUIDArchive" ? map[hex]! : map[hex + "#other"]!)
                copy.fields[i].value = .bytes(replacement.encoded())
            } else {
                let r = remappingUUIDs(sub, &map)
                if r != sub { copy.fields[i].value = .bytes(r.encoded()) }
            }
        }
        return copy
    }

    /// The copy's own entry in the package metadata. The locator has to name the file the copy was actually written
    /// to, whatever the original's entry said: a template component with **no** locator means "the file named by the
    /// preferred locator", and a copy that inherits that emptiness sends Numbers to the original's file — where the
    /// copy is not. Numbers then calls the whole document damaged and refuses to open it (Appendix B.18).
    /// What a rule paints, as a whole cell style — a `DifferentialStyle` says only what it changes, and the style
    /// writer builds archives out of complete styles.
    static func cellStyle(for d: DifferentialStyle) -> CellStyle {
        var style = CellStyle.default
        if let fill = d.fill { style.fill = fill }
        if let border = d.border { style.border = border }
        if let f = d.font {
            if let v = f.bold { style.font.bold = v }
            if let v = f.italic { style.font.italic = v }
            if let v = f.strikethrough { style.font.strikethrough = v }
            if let v = f.color { style.font.color = v }
            if let v = f.name { style.font.name = v; style.font.scheme = nil }
            if let v = f.size { style.font.size = v }
        }
        return style
    }

    /// The object a note's author is, minted once per name and registered with the document's author storage.
    private mutating func authorID(named name: String?) throws -> Int? {
        let name = (name?.isEmpty == false ? name! : "Author")
        if let hit = authorIDs[name] { return hit }
        guard let storage = doc.identifiers(ofType: "TSK.AnnotationAuthorStorageArchive").first,
              let file = doc.locations[storage]?.0 else { return nil }
        let id = try doc.add(NumbersRichText.author(named: name), file: file)
        doc.update(storage) { $0.append("annotation_author", reference: id) }
        authorIDs[name] = id
        return id
    }

    private mutating func registerComponent(_ new: Int, like old: Int) {
        let path = doc.locations[new]?.0 ?? ""
        var locator = path.hasPrefix("Index/") ? String(path.dropFirst("Index/".count)) : path
        if locator.hasSuffix(".iwa") { locator.removeLast(4) }
        pendingComponents.append((new: new, like: old, locator: locator))
    }

    /// Everything queued goes into the package metadata in one pass. Each pass re-walks the metadata, so doing
    /// this per object turned a one-second write into a two-minute one.
    private mutating func flushComponents() {
        guard !pendingComponents.isEmpty else { return }
        let queued = pendingComponents
        pendingComponents = []
        doc.update(NumbersDocument.packageID) { pkg in
            var comps = pkg.messages("components")
            var byID = Dictionary(comps.compactMap { c in c.int("identifier").map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
            let calcEngine = comps.firstIndex { $0.string("preferred_locator") == "CalculationEngine" }
            for entry in queued {
                var registered = false
                if let old = entry.like, let template = byID[old] {
                    var c = template
                    c.set("identifier", int: entry.new)
                    if !entry.locator.isEmpty { c.set("locator", string: entry.locator) }
                    comps.append(c)
                    byID[entry.new] = c
                    registered = true
                } else if entry.like == nil {
                    var c = ProtoMessage(typeName: "TSP.ComponentInfo")
                    c.set("identifier", int: entry.new)
                    c.set("preferred_locator", string: "Tables/Tile")
                    c.set("locator", string: entry.locator)
                    c.set("is_stored_outside_object_archive", bool: false)
                    for v in [2, 0, 0] { c.fields.append(ProtoMessage.Field(number: NumbersSchema.shared.fieldNumber("TSP.ComponentInfo", "document_read_version")!, value: .varint(UInt64(v)))) }
                    for v in [2, 0, 0] { c.fields.append(ProtoMessage.Field(number: NumbersSchema.shared.fieldNumber("TSP.ComponentInfo", "document_write_version")!, value: .varint(UInt64(v)))) }
                    c.set("save_token", int: 1)
                    comps.append(c)
                    byID[entry.new] = c
                    registered = true
                }
                // the calculation engine names every table component it uses — but only the ones that exist:
                // a copy whose original had no component entry gets none, and must not be referenced either
                if registered, let i = calcEngine {
                    var ref = ProtoMessage(typeName: "TSP.ComponentExternalReference")
                    ref.set("component_identifier", int: entry.new)
                    comps[i].append("external_references", message: ref)
                }
            }
            pkg.set("components", messages: comps)
        }
    }

    private func addExternalReference(toComponentNamed name: String, componentID: Int, objectID: Int?, weak: Bool = false) {
        doc.update(NumbersDocument.packageID) { pkg in
            var comps = pkg.messages("components")
            guard let i = comps.firstIndex(where: { $0.string("preferred_locator") == name }) else { return }
            var ref = ProtoMessage(typeName: "TSP.ComponentExternalReference")
            ref.set("component_identifier", int: componentID)
            if let objectID { ref.set("object_identifier", int: objectID) }
            if weak { ref.set("is_weak", bool: true) }
            comps[i].append("external_references", message: ref)
            pkg.set("components", messages: comps)
        }
    }

    /// Whatever a component said about an original object it now says about the copy: external references, and the
    /// object → UUID entries Numbers uses for cross-component identity (the template registers one per table object).
    private func duplicateComponentEntries(_ map: [Int: Int]) {
        doc.update(NumbersDocument.packageID) { pkg in
            var comps = pkg.messages("components")
            for i in comps.indices {
                var refAdditions: [ProtoMessage] = []
                for ref in comps[i].messages("external_references") {
                    if let o = ref.int("object_identifier"), let n = map[o] { var r = ref; r.set("object_identifier", int: n); refAdditions.append(r) }
                    else if ref.int("object_identifier") == nil, let c = ref.int("component_identifier"), let n = map[c] { var r = ref; r.set("component_identifier", int: n); refAdditions.append(r) }
                }
                for a in refAdditions { comps[i].append("external_references", message: a) }
                var uuidAdditions: [ProtoMessage] = []
                for entry in comps[i].messages("object_uuid_map_entries") {
                    guard let o = entry.int("identifier"), let n = map[o] else { continue }
                    var e = ProtoMessage(typeName: "TSP.ObjectUUIDMapEntry")
                    e.set("identifier", int: n)
                    e.set("uuid", message: NumbersUUID.random().uuid)
                    uuidAdditions.append(e)
                }
                for a in uuidAdditions { comps[i].append("object_uuid_map_entries", message: a) }
            }
            pkg.set("components", messages: comps)
        }
    }

    /// The identifier a cross-table reference names the table by — its `table_id` string, not its
    /// `haunted_owner` and not its dependency group's base owner. Numbers reads a reference carrying either of
    /// those as `#REF!`, which is how this was found (Appendix B.18).
    private func tableReferenceUUID(ofTableModel model: Int) -> ProtoMessage? {
        guard let id = doc.object(model)?.string("table_id") else { return nil }
        return NumbersUUID.cfuuid(fromString: id)
    }

    private mutating func cloneSheet() throws -> Int {
        let map = try clone(root: templateSheet)
        guard let new = map[templateSheet] else { throw SheetError.malformedPart(path: "empty.numbers", detail: "the template's sheet could not be copied") }
        // the copied table's drawable parent must be the copied sheet (remapping already did it); nothing else to fix
        return new
    }

    private mutating func cloneTable(from info: Int, intoSheet sid: Int) throws -> Int {
        let map = try clone(root: info, skipping: [sid])
        guard let new = map[info] else { throw SheetError.malformedPart(path: "empty.numbers", detail: "the template's table could not be copied") }
        doc.update(new) { m in
            var d = m.message("super") ?? ProtoMessage(typeName: "TSD.DrawableArchive")
            d.set("parent", reference: sid)
            m.set("super", message: d)
        }
        doc.update(sid) { $0.append("drawable_infos", reference: new) }
        return new
    }

    // MARK: - Pivot tables (Appendix B.19)

    /// One pivot table, as Numbers builds one: a **summary** table drawn on the sheet, and a **copy of the source
    /// rows** that belongs to no sheet at all and is reached only through the summary's table info. The rules that
    /// tie them together name the source's columns by UID, and a group tree says what groups the rows fall into.
    ///
    /// SwiftSheets computes the summary and writes it into the cells. Numbers rebuilds it from the rules when it
    /// opens the document — but our own reader, numbers-parser and LibreOffice see the cells and nothing else, so
    /// leaving them empty would be leaving the pivot empty for everyone but Numbers.
    private mutating func writePivot(_ pivot: PivotTable, summaryInfo: Int, sourceInfo: Int, onSheet sid: Int,
                                     sheetName: String, at y: Double) throws -> (width: Double, height: Double) {
        guard let columns = NumbersPivot.source(of: pivot, in: workbook) else {
            warnings.append(ConversionWarning(.dropped, subject: .objects, sheet: sheetName,
                                              message: "pivot table \(pivot.name) is dropped: its source range \(pivot.cache.sourceRef.a1) on \(pivot.cache.sourceSheet) is not in this workbook to summarise"))
            try discard(tableInfo: summaryInfo, fromSheet: sid); try discard(tableInfo: sourceInfo, fromSheet: sid)
            return (0, 0)
        }
        let rowFields = pivot.rowFields.filter { columns.indices.contains($0) }
        let columnFields = pivot.columnFields.filter { columns.indices.contains($0) }
        let dataFields = pivot.dataFields.filter { columns.indices.contains($0.field) }
        guard !dataFields.isEmpty, !(rowFields.isEmpty && columnFields.isEmpty) else {
            warnings.append(ConversionWarning(.dropped, subject: .objects, sheet: sheetName,
                                              message: "pivot table \(pivot.name) is dropped: a Numbers pivot needs at least one field to group by and one to summarise"))
            try discard(tableInfo: summaryInfo, fromSheet: sid); try discard(tableInfo: sourceInfo, fromSheet: sid)
            return (0, 0)
        }
        warnings.append(contentsOf: NumbersPivot.warnings(for: pivot, sheet: sheetName))

        // the copy of the source: the range's own cells, its heading row kept as a header row
        var sourceTable = Table(name: "\(pivot.name) Source")
        for (c, column) in columns.enumerated() {
            sourceTable[0, c] = .text(column.name)
            for (r, value) in column.values.enumerated() { sourceTable[r + 1, c] = value }
        }
        let sourceName = "\(pivot.cache.sourceSheet) as Pivot Source Table"
        _ = try patch(tableInfo: sourceInfo, with: sourceTable, name: sourceName, sheetName: sheetName)
        if let model = doc.object(sourceInfo)?.reference("tableModel") {
            doc.update(model) { $0.set("number_of_header_rows", int: 1) }   // the heading row of the range it copied
        }
        guard let sourceModel = doc.object(sourceInfo)?.reference("tableModel"),
              let summaryModel = doc.object(summaryInfo)?.reference("tableModel") else {
            throw SheetError.malformedPart(path: "empty.numbers", detail: "a pivot's table has no model")
        }

        // the summary itself
        let laid = NumbersPivot.summaryTable(pivot, source: columns, named: pivot.name,
                                             rowFields: rowFields, columnFields: columnFields, dataFields: dataFields)
        let size = try patch(tableInfo: summaryInfo, with: laid.table, name: pivot.name, sheetName: sheetName)
        // …and its own column / row UIDs. `patch` drops the template's, and a pivot's summary is the one table
        // that cannot do without them: the order map names its rows and columns by UID (Appendix B.19).
        let summaryUIDs = NumbersPivot.columnUIDMap(count: Swift.max(1, laid.table.columnCount),
                                                    rowCount: Swift.max(1, laid.table.rowCount))
        let summaryUIDsID = try doc.add(summaryUIDs.map, file: doc.locations[summaryModel]?.0 ?? "Index/Tables/Tile.iwa")
        registerComponent(summaryUIDsID, like: summaryModel)
        doc.update(summaryModel) { m in
            m.set("number_of_header_rows", int: laid.headerRows)
            m.set("number_of_header_columns", int: laid.headerColumns)
            m.set("base_column_row_uids", reference: summaryUIDsID)
        }

        // column UIDs: the rules name a source column by one of these, so the map has to exist before they do
        let rowCount = (columns.first?.values.count ?? 0) + 1
        let uids = NumbersPivot.columnUIDMap(count: columns.count, rowCount: rowCount)
        let file = doc.locations[sourceModel]?.0 ?? "Index/Tables/Tile.iwa"
        let uidMapID = try doc.add(uids.map, file: file)
        registerComponent(uidMapID, like: sourceModel)
        doc.update(sourceModel) { m in
            m.set("base_column_row_uids", reference: uidMapID)
            m.set("pivot_value_types_by_col", ints: columns.indices.map { i in
                dataFields.contains { $0.field == i } ? NumbersPivot.valueTypeAggregate : NumbersPivot.valueTypeGrouping
            })
        }

        // what groups there are. With column fields there are two group-bys on the source — one that walks the
        // column fields and then the row fields, one that walks the row fields alone — and with none, just the
        // one (Appendix B.19). The **first** is the group-by the cloned table already carries: it is registered
        // with the calculation engine and its table info already names its UUID, and a group-by the engine does
        // not own is a group-by Numbers does not read.
        let allRows = Array(1...Swift.max(1, columns.first?.values.count ?? 1))
        func tree(_ fields: [Int]) -> [NumbersPivot.GroupNode] {
            NumbersPivot.group(allRows, by: fields.map { columns[$0] })
        }
        let firstFields = columnFields.isEmpty ? rowFields : columnFields + rowFields
        guard let sourceCategoryID = doc.object(sourceModel)?.reference("category_owner"),
              let existing = doc.object(sourceCategoryID)?.references("group_by").first else {
            throw SheetError.malformedPart(path: "empty.numbers", detail: "the template's table has no category owner to make a pivot from")
        }
        // In a document Numbers wrote, the copy of the source is not a table in its own right: its dependency
        // owner is a **child of the pivot's own** (kind 100, based on the summary's base owner), and its group-bys
        // hang off that. Ours arrives as an independent clone, so it is re-parented here (Appendix B.19).
        let summaryBase = baseOwnerUUID(ofTableInfo: summaryInfo)
        let sourceBase = NumbersUUID.random().uuid
        try registerOwner(uid: sourceBase, kind: 100, base: summaryBase)

        var firstOutermost: [ProtoMessage] = []
        doc.update(existing) { m in
            let built = NumbersPivot.groupBy(columns: firstFields.map { uids.columns[$0] },
                                             nodes: tree(firstFields), allRows: allRows,
                                             ownerIndex: m.int("owner_index") ?? 8,
                                             uid: m.message("group_by_uid") ?? NumbersUUID.random().uuid)
            m = built.archive
            firstOutermost = built.outermost
        }
        var sourceGroupByIDs = [existing]
        // the two axes the summary is ordered by: the outermost nodes of the group-by that walks the columns, and
        // the outermost nodes of the one that walks the rows
        let columnAxis: [ProtoMessage] = columnFields.isEmpty ? [] : firstOutermost
        var rowAxis: [ProtoMessage] = columnFields.isEmpty ? firstOutermost : []
        if !columnFields.isEmpty {
            // …and a second one, which needs an owner of its own before Numbers will read it
            let uid = NumbersUUID.random().uuid
            let second = NumbersPivot.groupBy(columns: rowFields.map { uids.columns[$0] }, nodes: tree(rowFields),
                                              allRows: allRows, ownerIndex: 205, uid: uid)
            let id = try doc.add(second.archive, file: file)
            registerComponent(id, like: sourceModel)
            try registerOwner(uid: uid, kind: 205, base: sourceBase)
            sourceGroupByIDs.append(id)
            rowAxis = second.outermost
        }
        if rowFields.isEmpty { rowAxis = [] }
        doc.update(sourceCategoryID) { $0.set("group_by", references: sourceGroupByIDs) }
        if let firstUID = doc.object(existing)?.message("group_by_uid") { rebaseOwner(of: firstUID, onto: sourceBase) }

        // The summary keeps the empty, disabled group-by its clone came with — which is exactly what the summary
        // of a pivot carries in a document Numbers wrote.
        let summaryFile = doc.locations[summaryModel]?.0 ?? file

        // the rules
        let optionsID = try doc.add(ProtoMessage(typeName: "TST.PivotGroupingColumnOptionsMapArchive"), file: summaryFile)
        registerComponent(optionsID, like: summaryModel)
        // the pivot names the table it was made from — the one on the source sheet, not the copy it reads
        let originalInfo = (firstTableInfo[pivot.cache.sourceSheet] ?? nil) ?? sourceInfo
        let originalName = (doc.object(originalInfo)?.reference("tableModel")).flatMap { doc.object($0)?.string("table_name") } ?? sourceName
        let owner = NumbersPivot.pivotOwner(pivot, uid: NumbersUUID.random().uuid,
                                            sourceTableUID: baseOwnerUUID(ofTableInfo: originalInfo) ?? NumbersUUID.random().uuid,
                                            sourceTableName: originalName,
                                            rowColumns: rowFields.map { uids.columns[$0] },
                                            columnColumns: columnFields.map { uids.columns[$0] },
                                            aggregates: dataFields.map { (uids.columns[$0.field], $0.function) },
                                            optionsMap: optionsID)
        let ownerID = try doc.add(owner, file: summaryFile)
        registerComponent(ownerID, like: summaryModel)
        doc.update(summaryModel) { $0.set("pivot_owner", reference: ownerID) }

        // …and the table info that says the two models are one pivot
        let orderMapID = try doc.add(NumbersPivot.orderMap(columns: columnAxis, rows: rowAxis), file: summaryFile)
        registerComponent(orderMapID, like: summaryModel)
        var order = ProtoMessage(typeName: "TST.PivotOrderArchive")
        order.set("uid_map", reference: orderMapID)
        let orderID = try doc.add(order, file: summaryFile)
        registerComponent(orderID, like: summaryModel)
        let viewMapID = try doc.add(NumbersPivot.orderMap(columns: columnAxis, rows: rowAxis), file: summaryFile)
        registerComponent(viewMapID, like: summaryModel)
        doc.update(summaryInfo) { m in
            m.set("is_a_pivot_table", bool: true)
            m.set("pivot_data_model", reference: sourceModel)
            m.set("pivot_order", reference: orderID)
            m.set("view_column_row_uids", reference: viewMapID)
        }
        // the copy of the source is reached through the pivot, never through the sheet
        doc.update(sid) { m in
            let remaining = m.references("drawable_infos").filter { $0 != sourceInfo }
            m.set("drawable_infos", references: remaining)
        }
        doc.update(summaryInfo) { m in
            var d = m.message("super") ?? ProtoMessage(typeName: "TSD.DrawableArchive")
            var g = d.message("geometry") ?? ProtoMessage(typeName: "TSD.GeometryArchive")
            var p = ProtoMessage(typeName: "TSP.Point"); p.set("x", float: 0); p.set("y", float: Float(y))
            var sz = ProtoMessage(typeName: "TSP.Size"); sz.set("width", float: Float(size.width)); sz.set("height", float: Float(size.height))
            g.set("position", message: p); g.set("size", message: sz)
            d.set("geometry", message: g)
            m.set("super", message: d)
        }
        return size
    }

    /// A table cloned for a pivot that turned out not to be writable: taken off the sheet so it is not drawn as an
    /// empty table nobody asked for.
    private mutating func discard(tableInfo: Int, fromSheet sid: Int) throws {
        doc.update(sid) { m in
            let remaining = m.references("drawable_infos").filter { $0 != tableInfo }
            m.set("drawable_infos", references: remaining)
        }
    }

    /// A UUID the writer invented, made known to the calculation engine. A group-by whose UUID no owner claims is
    /// one Numbers does not read (Appendix B.19); the clone machinery mints these for the objects it copies, and
    /// this does the same for the ones a pivot adds.
    private mutating func registerOwner(uid: ProtoMessage, kind: Int, base: ProtoMessage?) throws {
        guard let file = doc.locations[calcEngineID]?.0 else { return }
        var owner = ProtoMessage(typeName: "TSCE.FormulaOwnerDependenciesArchive")
        owner.set("formula_owner_uid", message: uid)
        owner.set("owner_kind", int: kind)
        if let base { owner.set("base_owner_uid", message: base) }
        let next = (doc.object(calcEngineID)?.message("dependency_tracker")?.message("owner_id_map")?
            .messages("map_entry").compactMap { $0.int("internal_owner_id") }.max() ?? 0) + 1
        owner.set("internal_formula_owner_id", int: next)
        let id = try doc.add(owner, file: file)
        var entry = ProtoMessage(typeName: "TSCE.OwnerIDMapArchive.OwnerIDMapArchiveEntry")
        entry.set("internal_owner_id", int: next)
        if let cf = NumbersUUID.cfuuid(uid) { entry.set("owner_id", message: cf) }
        doc.update(calcEngineID) { ce in
            var tracker = ce.message("dependency_tracker") ?? ProtoMessage(typeName: "TSCE.DependencyTrackerArchive")
            var omap = tracker.message("owner_id_map") ?? ProtoMessage(typeName: "TSCE.OwnerIDMapArchive")
            omap.append("map_entry", message: entry)
            tracker.set("owner_id_map", message: omap)
            tracker.append("formula_owner_dependencies", reference: id)
            ce.set("dependency_tracker", message: tracker)
        }
    }

    /// Moves an existing dependency owner under another base — the copy of a source belongs to the pivot that
    /// reads it, not to a table of its own.
    private func rebaseOwner(of uid: ProtoMessage, onto base: ProtoMessage) {
        guard let hex = NumbersUUID.hex(uid) else { return }
        for fid in doc.identifiers(ofType: "TSCE.FormulaOwnerDependenciesArchive") {
            guard NumbersUUID.hex(doc.object(fid)?.message("formula_owner_uid")) == hex else { continue }
            doc.update(fid) { $0.set("base_owner_uid", message: base) }
            return
        }
    }

    /// The UUID a pivot names its source table by: the `formula_owner_uid` of the dependency owner that points at
    /// the table's own info — not its `haunted_owner`, and not its `table_id` (Appendix B.19).
    private func baseOwnerUUID(ofTableInfo info: Int) -> ProtoMessage? {
        for fid in doc.identifiers(ofType: "TSCE.FormulaOwnerDependenciesArchive") {
            guard let f = doc.object(fid), f.reference("formula_owner") == info else { continue }
            return f.message("formula_owner_uid")
        }
        return nil
    }

    // MARK: - Patching one table's data

    private mutating func patch(tableInfo: Int, with table: Table, name: String, sheetName: String,
                                conditionalFormats: [ConditionalFormatting] = []) throws -> (width: Double, height: Double) {
        guard let modelID = doc.object(tableInfo)?.reference("tableModel"), var model = doc.object(modelID), var store = model.message("base_data_store") else {
            throw SheetError.malformedPart(path: "empty.numbers", detail: "table model missing")
        }
        let rows = Swift.max(1, Swift.max(table.rowCount, table.nextAppendRow, (table.rowDimensions.keys.max() ?? -1) + 1, (table.merges.map(\.maxRow).max() ?? -1) + 1))
        let cols = Swift.max(1, Swift.max(table.columnCount, (table.columnDimensions.keys.max() ?? -1) + 1, (table.merges.map(\.maxCol).max() ?? -1) + 1))
        guard rows <= 1_000_000, cols <= 1000 else { throw SheetError.unsupportedFeature("Numbers tables are limited to 1,000,000 rows × 1,000 columns (\(rows)×\(cols) requested)") }
        model.set("number_of_rows", int: rows)
        model.set("number_of_columns", int: cols)
        model.set("table_name", string: name)
        model.set("table_name_enabled", bool: true)
        model.remove("base_column_row_uids")
        let defaultRowHeight = model.double("default_row_height") ?? NumbersWriter.defaultRowHeight
        let defaultColumnWidth = model.double("default_column_width") ?? NumbersWriter.defaultColumnWidth

        // covered cells of merges hold nothing
        var covered = Set<CellRef>()
        for m in table.merges { for ref in m.cells where ref != m.topLeft { covered.insert(ref) } }

        // strings → the string list (reset, keys from 1)
        var stringKeys: [String: Int] = [:]
        var stringEntries: [ProtoMessage] = []
        func key(for s: String) -> Int {
            if let k = stringKeys[s] { return k }
            let k = stringEntries.count + 1
            var e = ProtoMessage(typeName: "TST.TableDataList.ListEntry")
            e.set("key", int: k); e.set("refcount", int: 1); e.set("string", string: s)
            stringEntries.append(e); stringKeys[s] = k
            return k
        }

        // cell records per row, with the styles and number formats they name
        var records: [[Data?]] = Array(repeating: Array(repeating: nil, count: cols), count: rows)
        var styleWriter = NumbersStyleWriter(doc: doc, model: model)

        // formulas → the table's own formula list, the same shape as the string list. A formula the encoder has no
        // observed spelling for keeps the old behaviour: its cached value, and a warning saying which part stopped it.
        // A formula may name another table by the sheet ("Other!A1"), by the table ("'Table 2'!A1") or by both
        // ("'Other::Table 1'!A1"). All three are tried, in that order of exactness.
        let names = tableUUIDs
        var formulaEncoder = NumbersFormulaEncoder(hostTable: sheetName + "::" + name) { wanted in
            if let exact = names[wanted] { return exact }
            if let bySheet = names.keys.filter({ $0.hasPrefix(wanted + "::") }).sorted().first { return names[bySheet] }
            if let byTable = names.keys.filter({ $0.hasSuffix("::" + wanted) }).sorted().first { return names[byTable] }
            return nil
        }
        var formulaEntries: [ProtoMessage] = []
        var formulaKeys: [Data: Int] = [:]
        var formulaRefcounts: [Int: Int] = [:]
        func formulaKey(for archive: ProtoMessage) -> Int {
            let bytes = archive.encoded()
            if let existing = formulaKeys[bytes] {
                formulaRefcounts[existing, default: 1] += 1
                return existing
            }
            let k = formulaEntries.count + 1
            var e = ProtoMessage(typeName: "TST.TableDataList.ListEntry")
            e.set("key", int: k); e.set("refcount", int: 1); e.set("formula", message: archive)
            formulaEntries.append(e); formulaKeys[bytes] = k; formulaRefcounts[k] = 1
            return k
        }

        // conditional formats → the table's own list, and a key on every cell the rules cover. Numbers records
        // the rule on each cell rather than over a range, which is why the reader condenses them back (B.18).
        let tableUUID = model.message("haunted_owner")?.message("owner_uid")
        // Numbers keeps a rule set in the same file as the list that names it, and the two style archives a rule
        // paints with in another component again. Follow it: a set written into some other file is a reference
        // Numbers cannot resolve, and it refuses the whole document (Appendix B.18).
        let conditionalList = store.reference("conditionalstyletable")
        let conditionalFile = conditionalList.flatMap { doc.locations[$0]?.0 } ?? NumbersStyleWriter.stylesheetFile
        var conditionalEntries: [ProtoMessage] = []
        var conditionalKeys: [CellRef: Int] = [:]
        var unwritableRules: [String] = []
        for block in conditionalFormats {
            var rules: [ProtoMessage] = []
            for rule in block.rules.sorted(by: { $0.priority < $1.priority }) {
                let painted = NumbersWriter.cellStyle(for: rule.style ?? DifferentialStyle())
                let objects = try styleWriter.archives(for: painted)
                guard let archive = NumbersConditional.archive(for: rule, tableUUID: tableUUID,
                                                               cellStyle: objects.cell ?? styleWriter.defaultCellStyle,
                                                               textStyle: objects.text ?? styleWriter.defaultTextStyle) else {
                    unwritableRules.append(rule.kind.rawValue)
                    continue
                }
                rules.append(archive)
            }
            guard !rules.isEmpty else { continue }
            var set = ProtoMessage(typeName: "TST.ConditionalStyleSetArchive")
            set.set("ruleCount", int: rules.count)
            var holder = ProtoMessage(typeName: "TST.ConditionalStyleSetArchive.ConditionalStyleRules")
            holder.set("rule", messages: rules)
            set.set("rules", message: holder)
            let id = try doc.add(set, file: conditionalFile)
            let key = conditionalEntries.count + 1
            var entry = ProtoMessage(typeName: "TST.TableDataList.ListEntry")
            entry.set("key", int: key); entry.set("refcount", int: 0); entry.set("reference", reference: id)
            conditionalEntries.append(entry)
            for range in block.ranges.ranges {
                for r in range.minRow...range.maxRow where r < rows {
                    for c in range.minCol...range.maxCol where c < cols {
                        conditionalKeys[CellRef(row: r, col: c)] = key
                    }
                }
            }
        }
        for kind in Set(unwritableRules).sorted() {
            warnings.append(ConversionWarning(.dropped, subject: .formatting, sheet: sheetName,
                                              message: "conditional format \(kind) is dropped: Numbers has no rule of that kind (it drops the same ones when it imports an Excel file)"))
        }
        for i in conditionalEntries.indices {
            let key = conditionalEntries[i].int("key") ?? 0
            conditionalEntries[i].set("refcount", int: conditionalKeys.values.filter { $0 == key }.count)
        }

        // a link, formatting that changes part-way through the text, and a note: three things a cell keeps
        // outside its value, each in a list of its own (Appendix B.18)
        let richList = store.reference("rich_text_table")
        let richFile = richList.flatMap { doc.locations[$0]?.0 } ?? NumbersStyleWriter.stylesheetFile
        let commentList = store.reference("commentStorageTable")
        let commentFile = commentList.flatMap { doc.locations[$0]?.0 } ?? NumbersStyleWriter.stylesheetFile
        let plainRun = NumbersRichText.templateCharacterStyle("character-style-null", in: doc)
        let linkRun = NumbersRichText.templateCharacterStyle("character-style-hyperlink", in: doc)
        let listStyle = NumbersRichText.templateListStyle(in: doc)
        var richEntries: [ProtoMessage] = [], commentEntries: [ProtoMessage] = []

        /// The rich-text list key for a cell that carries a link, formatting runs, or both.
        func richKey(text: String, runs: [TextRun], link: String?) throws -> Int? {
            var attributes: [(index: Int, style: Int?)] = []
            var index = 0
            for run in runs {
                var style: Int?
                if let font = run.font, let parent = plainRun { style = try styleWriter.characterArchive(for: font, parent: parent) }
                attributes.append((index, style))
                index += run.text.count
            }
            var fields: [(index: Int, object: Int)] = []
            if let link {
                let field = try doc.add(NumbersRichText.hyperlink(link), file: richFile)
                fields.append((0, field))
                if attributes.isEmpty, let linkRun { attributes.append((0, linkRun)) }
            }
            guard !attributes.isEmpty || !fields.isEmpty else { return nil }
            let storageID = try doc.add(NumbersRichText.storage(text: text, stylesheet: styleWriter.stylesheetID,
                                                               paragraphStyle: styleWriter.defaultTextStyle,
                                                               listStyle: listStyle, runs: attributes, fields: fields),
                                        file: richFile)
            let payloadID = try doc.add(NumbersRichText.payload(storage: storageID), file: richFile)
            let key = richEntries.count + 1
            var entry = ProtoMessage(typeName: "TST.TableDataList.ListEntry")
            entry.set("key", int: key); entry.set("refcount", int: 1); entry.set("rich_text_payload", reference: payloadID)
            richEntries.append(entry)
            return key
        }

        /// The comment-list key for a cell that carries a note.
        func commentKey(for note: CellNote) throws -> Int {
            let archive = NumbersRichText.comment(note, author: try authorID(named: note.author))
            let id = try doc.add(archive, file: commentFile)
            let key = commentEntries.count + 1
            var entry = ProtoMessage(typeName: "TST.TableDataList.ListEntry")
            entry.set("key", int: key); entry.set("refcount", int: 1); entry.set("comment_storage", reference: id)
            commentEntries.append(entry)
            return key
        }

        for (ref, cell) in table.cells where ref.row < rows && ref.col < cols && !covered.contains(ref) {
            guard let stored = cell.value else { continue }
            var value: CellValue? = stored
            var formulaID: Int?
            if case .formula(let expr, let cached) = stored {
                let seen = formulaEncoder.problems.count
                if let archive = formulaEncoder.archive(for: expr, row: ref.row, col: ref.col) {
                    formulaID = formulaKey(for: archive)
                    value = cached
                } else {
                    let why = formulaEncoder.problems.dropFirst(seen).first ?? "the formula has no Numbers spelling"
                    warnings.append(ConversionWarning(.degraded, subject: .formulas, sheet: sheetName, location: ref,
                                                      message: "formula written as its cached value: \(why)"))
                    guard let c = cached else { continue }
                    value = c
                }
            }
            // A link, or formatting that changes part-way through, moves the cell's text into the document
            // engine — and the engine holds *text*. A link on a number would turn the number into a string, so
            // the number wins and the link is reported instead.
            var richID: Int?
            var isRich = false
            if case .richText = value { isRich = true }
            if isRich || cell.hyperlink != nil {
                let carriesText = isRich || { if case .text = value { return true }; return value == nil }()
                if carriesText {
                    let runs: [TextRun]
                    let text: String
                    if case .richText(let r) = value { runs = r; text = r.map(\.text).joined() } else { runs = []; text = value?.stringValue ?? "" }
                    richID = try richKey(text: text, runs: runs, link: cell.hyperlink?.target)
                    if richID != nil { value = nil }
                } else {
                    warnings.append(ConversionWarning(.dropped, subject: .other, sheet: sheetName, location: ref,
                                                      message: "the link on a cell holding a \(value.map { "\($0)" }.map { $0.prefix(while: { $0 != "(" }) } ?? "value") is dropped: a Numbers link lives inside text, and the value is worth more than the link"))
                }
            }
            let commentID = try cell.comment.map { try commentKey(for: $0) }
            let style = cell.style
            let keys = try styleWriter.keys(for: style)
            let formatKey = style.numberFormat == NumberFormat.general ? nil : styleWriter.formatKey(for: style.numberFormat)
            records[ref.row][ref.col] = record(for: value, key: key, cellStyleID: keys.cell, textStyleID: keys.text,
                                               formatKey: formatKey, code: style.numberFormat, formulaID: formulaID,
                                               conditionalStyleID: conditionalKeys[ref], richID: richID, commentID: commentID)
        }
        for i in formulaEntries.indices {
            let k = formulaEntries[i].int("key") ?? 0
            formulaEntries[i].set("refcount", int: formulaRefcounts[k] ?? 1)
        }
        // an empty cell inside a rule's range still names the rule — otherwise the rule stops at the last cell
        // that happened to hold something
        for (ref, key) in conditionalKeys where records[ref.row][ref.col] == nil {
            records[ref.row][ref.col] = CellStorage.encode(type: .generic, conditionalStyleID: key)
        }
        for code in styleWriter.unexpressibleFormats {
            warnings.append(ConversionWarning(.substituted, subject: .formatting, sheet: sheetName,
                                              message: "number format \(code) has no Numbers equivalent; the cells keep their value unformatted"))
        }
        for code in styleWriter.literalFormats {
            warnings.append(ConversionWarning(.substituted, subject: .formatting, sheet: sheetName,
                                              message: "number format \(code): Numbers does not draw the literal text beside the number, though the code survives a round trip and the value is never rescaled"))
        }
        for code in styleWriter.partialFormats {
            warnings.append(ConversionWarning(.substituted, subject: .formatting, sheet: sheetName,
                                              message: "number format \(code): Numbers describes one presentation, so its colours, conditions and negative section are dropped"))
        }
        // the style / format lists of this table
        if let sid = store.reference("styleTable") {
            let entries = styleWriter.styleEntries
            doc.update(sid) { list in
                list.set("entries", messages: entries)
                list.set("nextListID", int: entries.count + 1)
            }
            // the list names objects of the stylesheet component; Numbers keeps that crossing in the metadata
            if let listComponent = doc.componentID(forObject: sid) {
                let crossings = styleWriter.styleObjects.compactMap { object in
                    doc.componentID(forObject: object).map { (object: object, component: $0) }
                }
                doc.addExternalReferences(from: listComponent, to: crossings)
            }
        }
        if let fid = store.reference("format_table") {
            let entries = styleWriter.formatEntries
            doc.update(fid) { list in
                list.set("entries", messages: entries)
                list.set("nextListID", int: entries.count + 1)
            }
        }

        // conditional-style list
        if let cid = conditionalList {
            let entries = conditionalEntries
            doc.update(cid) { list in
                list.set("entries", messages: entries)
                list.set("nextListID", int: entries.count + 1)
            }
            if !entries.isEmpty, let listComponent = doc.componentID(forObject: cid) {
                // every style a rule names, minted or borrowed. The table's own defaults stand in for the half a
                // rule does not vary, and they live in the stylesheet component just as the minted ones do — an
                // undeclared crossing is a reference Numbers cannot resolve, and it refuses the document.
                let named = styleWriter.allStyleObjects + [styleWriter.defaultCellStyle, styleWriter.defaultTextStyle].compactMap { $0 }
                let crossings = Set(named).compactMap { object in
                    doc.componentID(forObject: object).map { (object: object, component: $0) }
                }
                doc.addExternalReferences(from: listComponent, to: crossings)
            }
        } else if !conditionalEntries.isEmpty {
            warnings.append(ConversionWarning(.dropped, subject: .formatting, sheet: sheetName,
                                              message: "conditional formats dropped: the template's table has no conditional-style list"))
        }

        // rich-text and comment lists
        if let rid = richList, !richEntries.isEmpty {
            let entries = richEntries
            doc.update(rid) { list in
                list.set("entries", messages: entries)
                list.set("nextListID", int: entries.count + 1)
            }
            if let component = doc.componentID(forObject: rid) {
                // everything the storage names and does not live beside it: the stylesheet, the styles a run
                // wears, the paragraph and list styles. An undeclared crossing is a document Numbers will not open.
                let named = styleWriter.allStyleObjects
                    + [plainRun, linkRun, listStyle, styleWriter.stylesheetID, styleWriter.defaultTextStyle].compactMap { $0 }
                let crossings = Set(named).compactMap { object in
                    doc.componentID(forObject: object).map { (object: object, component: $0) }
                }
                doc.addExternalReferences(from: component, to: crossings)
            }
        }
        if let cid = commentList, !commentEntries.isEmpty {
            let entries = commentEntries
            doc.update(cid) { list in
                list.set("entries", messages: entries)
                list.set("nextListID", int: entries.count + 1)
            }
            if let component = doc.componentID(forObject: cid) {
                let crossings = authorIDs.values.compactMap { object in
                    doc.componentID(forObject: object).map { (object: object, component: $0) }
                }
                doc.addExternalReferences(from: component, to: crossings)
            }
        }

        // formula list
        if let fid = store.reference("formula_table") {
            let entries = formulaEntries
            doc.update(fid) { list in
                list.set("entries", messages: entries)
                list.set("nextListID", int: entries.count + 1)
            }
        } else if !formulaEntries.isEmpty {
            warnings.append(ConversionWarning(.degraded, subject: .formulas, sheet: sheetName,
                                              message: "\(formulaEntries.count) formula(s) written as their cached value: the template's table has no formula list"))
        }

        // string list
        if let sid = store.reference("stringTable") {
            doc.update(sid) { list in
                list.set("entries", messages: stringEntries)
                list.set("nextListID", int: stringEntries.count + 1)
            }
        }
        // row / column headers
        if let bucket = store.message("rowHeaders")?.references("buckets").first {
            doc.update(bucket) { b in
                var headers: [ProtoMessage] = []
                for r in 0..<rows {
                    var h = ProtoMessage(typeName: "TST.HeaderStorageBucket.Header")
                    let dim = table.rowDimensions[r]
                    h.set("index", int: r); h.set("size", float: Float(dim?.height ?? defaultRowHeight)); h.set("hidingState", int: dim?.hidden == true ? 1 : 0)
                    h.set("numberOfCells", int: records[r].filter { $0 != nil }.count)
                    headers.append(h)
                }
                b.set("headers", messages: headers)
            }
        }
        if let cb = store.reference("columnHeaders") {
            doc.update(cb) { b in
                var headers: [ProtoMessage] = []
                for c in 0..<cols {
                    var h = ProtoMessage(typeName: "TST.HeaderStorageBucket.Header")
                    let dim = table.columnDimensions[c]
                    h.set("index", int: c); h.set("size", float: Float(dim?.width.map { $0 * NumbersReader.pointsPerCharacter } ?? defaultColumnWidth)); h.set("hidingState", int: dim?.hidden == true ? 1 : 0)
                    h.set("numberOfCells", int: records.filter { $0[c] != nil }.count)
                    headers.append(h)
                }
                b.set("headers", messages: headers)
            }
        }
        // merges → a fresh region map
        var mergeMap = ProtoMessage(typeName: "TST.MergeRegionMapArchive")
        for m in table.merges {
            var range = ProtoMessage(typeName: "TST.CellRange")
            var origin = ProtoMessage(typeName: "TST.CellID"); origin.set("packedData", int: (m.minCol << 16) | m.minRow)
            var size = ProtoMessage(typeName: "TST.TableSize"); size.set("packedData", int: ((m.maxCol - m.minCol + 1) << 16) | (m.maxRow - m.minRow + 1))
            range.set("origin", message: origin); range.set("size", message: size)
            mergeMap.append("cell_range", message: range)
        }
        let mergeID = try doc.add(mergeMap, file: "Index/CalculationEngine.iwa")
        store.set("merge_region_map", reference: mergeID)

        // tiles
        var tileStorage = store.message("tiles") ?? ProtoMessage(typeName: "TST.TileStorage")
        tileStorage.remove("tiles")
        tileStorage.set("tile_size", int: NumbersWriter.tileSize)
        tileStorage.set("should_use_wide_rows", bool: true)
        var tileRefs: [ProtoMessage] = []
        var tileIndex = 0
        while tileIndex * NumbersWriter.tileSize < rows {
            let rowStart = tileIndex * NumbersWriter.tileSize
            let rowEnd = Swift.min(rows, rowStart + NumbersWriter.tileSize)
            var tile = ProtoMessage(typeName: "TST.Tile")
            tile.set("maxColumn", int: 0); tile.set("maxRow", int: 0); tile.set("numCells", int: 0); tile.set("numrows", int: rowEnd - rowStart)
            tile.set("storage_version", int: 5); tile.set("last_saved_in_BNC", bool: true); tile.set("should_use_wide_rows", bool: true)
            var infos: [ProtoMessage] = []
            for r in rowStart..<rowEnd {
                var info = ProtoMessage(typeName: "TST.TileRowInfo")
                info.set("tile_row_index", int: r - rowStart)
                var storage = Data(), offsets = [Int16](repeating: -1, count: cols), count = 0
                for c in 0..<cols {
                    guard let rec = records[r][c] else { continue }
                    offsets[c] = Int16(storage.count >> 2)
                    storage.append(rec)
                    count += 1
                }
                info.set("cell_count", int: count)
                var offsetBytes = Data()
                for o in offsets { let u = UInt16(bitPattern: o); offsetBytes.append(UInt8(u & 0xFF)); offsetBytes.append(UInt8(u >> 8)) }
                info.set("cell_offsets", bytes: offsetBytes)
                info.set("cell_offsets_pre_bnc", bytes: NumbersWriter.preBNCBytes)
                info.set("storage_version", int: 5)
                info.set("cell_storage_buffer", bytes: storage)
                info.set("cell_storage_buffer_pre_bnc", bytes: NumbersWriter.preBNCBytes)
                info.set("has_wide_offsets", bool: true)
                infos.append(info)
            }
            tile.set("rowInfos", messages: infos)
            let tileID = try doc.add(tile, file: "Index/Tables/Tile-{id}.iwa")
            registerTileComponent(tileID)
            var ref = ProtoMessage(typeName: "TST.TileStorage.Tile")
            ref.set("tileid", int: tileIndex); ref.set("tile", reference: tileID)
            tileRefs.append(ref)
            tileIndex += 1
        }
        // drop the template's old tiles from the package and insert the new references in field order
        for old in store.message("tiles")?.messages("tiles").compactMap({ $0.reference("tile") }) ?? [] { doc.remove(old) }
        tileStorage.set("tiles", messages: tileRefs)
        store.set("tiles", message: tileStorage)
        model.set("base_data_store", message: store)
        doc.replace(modelID, with: model)

        let width = (0..<cols).reduce(0.0) { $0 + (table.columnDimensions[$1]?.width.map { $0 * NumbersReader.pointsPerCharacter } ?? defaultColumnWidth) }
        let height = (0..<rows).reduce(0.0) { $0 + (table.rowDimensions[$1]?.height ?? defaultRowHeight) }
        return (width, height)
    }

    private mutating func registerTileComponent(_ id: Int) {
        let path = doc.locations[id]?.0 ?? ""
        var locator = path.hasPrefix("Index/") ? String(path.dropFirst("Index/".count)) : path
        if locator.hasSuffix(".iwa") { locator.removeLast(4) }
        pendingComponents.append((new: id, like: nil, locator: locator))
    }

    /// The packed record for a value (nil for kinds Numbers cannot hold, after a warning). The number format goes
    /// in the slot the *value* asks for — Numbers has one per kind, not one per cell.
    private mutating func record(for value: CellValue?, key: (String) -> Int, cellStyleID: Int? = nil, textStyleID: Int? = nil,
                                 formatKey: Int? = nil, code: String = NumberFormat.general, formulaID: Int? = nil,
                                 conditionalStyleID: Int? = nil, richID: Int? = nil, commentID: Int? = nil) -> Data? {
        let isCurrency = code.contains("$") || code.contains("¥") || code.contains("€") || code.contains("£")
        func encode(_ type: CellStorage.CellType, decimal: Decimal? = nil, double: Double? = nil, seconds: Double? = nil,
                    stringID: Int? = nil) -> Data {
            var number: Int?, currency: Int?, date: Int?, duration: Int?, text: Int?, boolean: Int?
            switch type {
            case .text, .automatic: text = formatKey
            case .date: date = formatKey
            case .duration: duration = formatKey
            case .bool: boolean = formatKey
            default: if isCurrency { currency = formatKey } else { number = formatKey }
            }
            return CellStorage.encode(type: isCurrency && type == .number ? .currency : type, decimal: decimal, double: double,
                                      seconds: seconds, stringID: stringID, richID: richID, commentID: commentID,
                                      cellStyleID: cellStyleID, textStyleID: textStyleID,
                                      conditionalStyleID: conditionalStyleID, formulaID: formulaID, numFormatID: number, currencyFormatID: currency, dateFormatID: date,
                                      durationFormatID: duration, textFormatID: text, boolFormatID: boolean)
        }
        switch value {
        case nil:
            // a cell whose text lives in the rich-text list, or a formula whose result the source never cached
            if richID != nil { return encode(.automatic) }
            return formulaID == nil && commentID == nil ? nil : encode(.generic)
        case .text(let s): return encode(.text, stringID: key(s))
        case .richText(let runs): return encode(.text, stringID: key(runs.map(\.text).joined()))
        case .integer(let i): return encode(.number, decimal: Decimal(i))
        case .number(let d): return encode(.number, decimal: d)
        case .bool(let b): return encode(.bool, double: b ? 1 : 0)
        case .date(let dt):
            let seconds = Double(dt.date.dayNumber - NumbersReader.epochDay) * 86400 + dt.time.dayFraction * 86400
            return encode(.date, seconds: seconds)
        case .time(let t):   // a time of day is a date on the epoch day
            return encode(.date, seconds: t.dayFraction * 86400)
        case .duration(let d):
            let (s, attos) = d.components
            return encode(.duration, double: Double(s) + Double(attos) / 1e18)
        case .error(let e): return encode(.text, stringID: key(e))
        case .formula: return nil
        }
    }
}
