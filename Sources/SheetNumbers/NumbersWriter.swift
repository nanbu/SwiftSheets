import Foundation
import SheetCore

/// Template-patch writer (spec §11.1, Appendix B.8): the empty document is loaded, its one sheet / table subgraph is
/// patched (or cloned for further sheets and tables), cells are packed into tiles, strings into the string list.
/// Every object the model does not touch stays as the template had it. Formulas are written as formula archives
/// since B.18; the cached-value fallback with a `degraded` warning remains only for what has no Numbers spelling.
struct NumbersWriter {
    static let tileSize = 256
    static let preBNCBytes = Data("🤠".utf8)   // what Numbers itself writes in the legacy fields
    static let defaultRowHeight = 20.0
    static let defaultColumnWidth = 98.0
    static let tableGap = 80.0
    /// Whether a pivot table is written as a **Numbers pivot** — a live summary Numbers recomputes from the rows
    /// it is given — rather than dropped with a warning (Appendix B.19 / B.28). On since the judge passed it:
    /// Numbers 15.3.1 draws all seventeen of the probe workbook's pivots with every number right and not one
    /// coordinate assertion. What is not written is named instead — see `writes(_:)`.
    static let writesPivotTables = true

    /// Every pivot shape is written since Appendix B.28 — several fields on either axis included (a group's own
    /// subtotal lane after its members, one group-by per column-field prefix) — with one trim: of several
    /// summarised values, the **first is kept and the rest are dropped, out loud**. The lanes of a no-group axis
    /// all carry the same placeholder id, a document this writer builds is always rebuilt on open (the
    /// old-version template), and a rebuilt view resolves each lane through that shared id — so a second value
    /// lane cannot round-trip: every arrangement measured (value order, lane ids, the body formulas Numbers
    /// itself writes) drew one value or none. Numbers' own document survives only because it is never rebuilt
    /// (Appendix B.28).
    static func writes(_ pivot: PivotTable) -> Bool { true }

    /// `TSTControlCellSpec` interaction type of a pop-up menu.
    static let popupInteractionType = 7

    /// The interaction types of the controls the model has a word for (measured from a document Numbers 15.3.1
    /// built when its own AppleScript `format` property was set to each; Appendix B.25).
    static let controlInteractionTypes: [CellControl.Kind: Int] = [.stepper: 4, .slider: 5, .rating: 6, .checkbox: 8]

    /// The choices of a validation that can go out as a Numbers pop-up menu: a `.list` whose choices are spelt in
    /// the rule itself (`"a,b,c"`). Anything else returns nil — a range-sourced list would have to be frozen into
    /// today's values, which changes what the rule means, and the other kinds have no control to become.
    static func popupItems(of v: DataValidation) -> [String]? {
        guard v.kind == .list, let f = v.formula1, f.count >= 2, f.hasPrefix("\""), f.hasSuffix("\"") else { return nil }
        let items = f.dropFirst().dropLast().split(separator: ",").map(String.init).filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }

    /// One choice of a pop-up menu, the way Numbers itself writes one (`TSCE.CellValueArchive`): nil is the blank
    /// choice every menu carries first, a numeric spelling keeps both its binary and decimal forms, text is text.
    static func popupChoice(_ item: String?) -> ProtoMessage {
        var value = ProtoMessage(typeName: "TSCE.CellValueArchive")
        let kind = { NumbersSchema.shared.enumValue("TSCE.CellValueArchive.CellValueType", $0) ?? 1 }
        guard let item else { value.set("cell_value_type", int: kind("NIL_TYPE")); return value }
        var format = ProtoMessage(typeName: "TSK.FormatStructArchive")
        if let number = Decimal(string: item), "\(number)" == item {
            value.set("cell_value_type", int: kind("NUMBER_TYPE"))
            var archive = ProtoMessage(typeName: "TSCE.NumberCellValueArchive")
            archive.set("value", double: (number as NSDecimalNumber).doubleValue)
            archive.set("unit_index", int: 0)
            format.set("format_type", int: NumbersFormat.type("DECIMAL") ?? 256)
            format.set("decimal_places", int: NumbersFormat.automaticDecimals)
            format.set("negative_style", int: 0)
            format.set("show_thousands_separator", bool: false)
            archive.set("format", message: format)
            archive.set("format_is_explicit", bool: false)
            let bytes = CellStorage.encodeDecimal128(number)
            var low: UInt64 = 0, high: UInt64 = 0
            for k in 0..<8 { low |= UInt64(bytes[k]) << (8 * UInt64(k)); high |= UInt64(bytes[8 + k]) << (8 * UInt64(k)) }
            archive.set("decimal_low", uint: low)
            archive.set("decimal_high", uint: high)
            value.set("number_value", message: archive)
        } else {
            value.set("cell_value_type", int: kind("STRING_TYPE"))
            var archive = ProtoMessage(typeName: "TSCE.StringCellValueArchive")
            archive.set("value", string: item)
            format.set("format_type", int: NumbersFormat.type("TEXT") ?? 260)
            archive.set("format", message: format)
            archive.set("format_is_explicit", bool: false)
            archive.set("is_regex", bool: false)
            archive.set("is_case_sensitive_regex", bool: false)
            value.set("string_value", message: archive)
        }
        return value
    }

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
    /// Crossings a table's own lists make into objects that live elsewhere — the stylesheet, mostly. They are
    /// recorded by object id and resolved after `flushComponents()`, never while a sheet is being written: a
    /// **copied** sheet's component is only queued at that point, so `componentID(forObject:)` answers nil and
    /// the crossing used to be skipped altogether. The document that came out was one Numbers refused to open,
    /// and nothing said so (spec Appendix B.37).
    private var pendingCrossings: [(from: Int, to: [Int])] = []

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
            warnings.append(ConversionWarning(.dropped, subject: .objects, message: "\(workbook.preserved.opaqueParts.count) part(s) preserved from the \(src.rawValue) file cannot be carried into Numbers"))
        }
        // the macros are named on their own: "parts" would send the reader to XLSX, which loses them too
        if workbook.preserved.hasVBAProject {
            warnings.append(ConversionWarning(.dropped, subject: .macros, message: "VBA project dropped: Numbers has no place for it (write .xlsm to keep the macros)"))
        }
        for sheet in workbook.sheets where !sheet.images.isEmpty {
            warnings.append(ConversionWarning(.dropped, subject: .objects, sheet: sheet.name,
                                              message: "\(sheet.images.count) image(s) added by addImage dropped: writing pictures into Numbers is not implemented yet (write .xlsx to keep them)"))
        }
        for sheet in workbook.sheets where !sheet.charts.isEmpty {
            warnings.append(ConversionWarning(.dropped, subject: .objects, sheet: sheet.name,
                                              message: "\(sheet.charts.count) chart(s) added by addChart dropped: writing charts into Numbers is not implemented yet (write .xlsx to keep them)"))
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
            let writablePivots = sheet.pivotTables.filter { NumbersWriter.writes($0) }
            let wanted = Swift.max(1, sheet.tables.count)
                + (NumbersWriter.writesPivotTables ? 2 * writablePivots.count : 0)
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
            // a list rule that spells its choices becomes a pop-up menu (in `patch`); the rest have no control to become
            let popupRules = sheet.dataValidations.compactMap { rule in NumbersWriter.popupItems(of: rule).map { (rule: rule, items: $0) } }
            let unwritableRules = sheet.dataValidations.count - popupRules.count
            if unwritableRules > 0 || sheet.hasUnmodelledValidations {
                warnings.append(ConversionWarning(.dropped, subject: .formatting, sheet: sheet.name,
                                                  message: "\(Swift.max(unwritableRules, 1)) data validation rule(s) dropped: only a list whose choices are spelt in the rule becomes a Numbers pop-up menu"))
            }
            if sheet.tables.count > 1, !popupRules.isEmpty {
                warnings.append(ConversionWarning(.degraded, subject: .formatting, sheet: sheet.name,
                                                  message: "the sheet's pop-up menus are written onto its first table: the model keeps data validations per sheet, Numbers per table"))
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
            if sheet.protection.enabled {
                warnings.append(ConversionWarning(.dropped, subject: .other, sheet: sheet.name, message: "sheet protection is dropped: Numbers protects a whole document, not a sheet"))
            }
            if !sheet.protectedRanges.isEmpty {
                warnings.append(ConversionWarning(.dropped, subject: .other, sheet: sheet.name, message: "\(sheet.protectedRanges.count) protected range(s) dropped: Numbers has no window left open inside a protected sheet"))
            }
            let arrays = sheet.tables.reduce(0) { $0 + $1.arrayFormulas.count }
            if arrays > 0 {
                warnings.append(ConversionWarning(.degraded, subject: .formulas, sheet: sheet.name, message: "\(arrays) array formula(s) written as the anchor's formula and the covered cells' values: Numbers' own spill function does not survive its load-time recalculation, so the range is not kept (Appendix B.26)"))
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
                                     conditionalFormats: t == 0 ? sheet.conditionalFormatting : [],
                                     popupRules: t == 0 ? popupRules : [])
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
        registerPendingCrossings()
        doc.update(NumbersDocument.documentID) { $0.set("sheets", references: sheetIDs) }
        doc.setBlob("Metadata/DocumentIdentifier", Data(UUID().uuidString.utf8))
        return doc.encoded()
    }

    // MARK: - Cloning (further sheets / tables)

    /// Types that belong to one table / sheet and are copied; everything else (styles, presets, the stylesheet) is shared.
    static let clonedTypes: Set<String> = [
        "TN.SheetArchive", "TSD.GuideStorageArchive", "TSWP.StorageArchive", "TST.TableInfoArchive", "TST.TableModelArchive", "TST.SummaryModelArchive",
        "TST.CategoryOrderArchive", "TSA.StandinCaptionArchive", "TSA.CaptionInfoArchive", "TSA.CaptionPlacementArchive", "TST.HeaderStorageBucket", "TST.Tile",
        "TST.TableDataList", "TST.HiddenStateFormulaOwnerArchive", "TST.FilterSetArchive", "TST.ColumnRowUIDMapArchive",
        // TSCE, not TST: with the wrong prefix here the sort-rule reference tracker was never cloned, so every
        // table cloned from the template shared the template's one — and two tables of a pivot sharing a runtime
        // tracker is what stopped Numbers adopting the pivot's grouping while computing all of its totals
        // (Appendix B.19; found by scanning the two models for objects both referenced)
        "TSCE.TrackedReferenceStoreArchive",
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

    /// Every crossing collected while the sheets were written, now that `flushComponents()` has put every
    /// component into the package metadata and `componentID(forObject:)` can answer for all of them.
    private mutating func registerPendingCrossings() {
        let waiting = pendingCrossings
        pendingCrossings = []
        for entry in waiting {
            guard let from = doc.componentID(forObject: entry.from) else {
                warnings.append(ConversionWarning(.degraded, subject: .formatting,
                                                  message: "object \(entry.from) is in no component, so \(entry.to.count) "
                                                  + "cross-component reference(s) could not be recorded; Numbers may refuse the document"))
                continue
            }
            let crossings = entry.to.compactMap { object in
                doc.componentID(forObject: object).flatMap { $0 == from ? nil : (object: object, component: $0) }
            }
            doc.addExternalReferences(from: from, to: crossings)
        }
        for entry in doc.flushPendingExternalReferences() {
            warnings.append(ConversionWarning(.degraded, subject: .formatting,
                                              message: "\(entry.objects.count) cross-component reference(s) could not be recorded "
                                              + "for component \(entry.component); Numbers may refuse the document"))
        }
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
        var dataFields = pivot.dataFields.filter { columns.indices.contains($0.field) }
        // Of several summarised values the first is kept: the lanes of a no-group axis all share one placeholder
        // id, a document this writer builds is rebuilt when Numbers opens it, and the rebuilt view resolves each
        // lane through that shared id — so a second value lane comes up empty however it is written (measured
        // across every arrangement; Numbers' own two-value document survives only because it is never rebuilt).
        if dataFields.count > 1 {
            warnings.append(ConversionWarning(.degraded, subject: .objects, sheet: sheetName,
                                              message: "pivot table \(pivot.name): \(dataFields.count - 1) of its \(dataFields.count) summarised values dropped — the value lanes of a rebuilt Numbers pivot share one placeholder id and cannot be told apart, so only the first value survives the trip"))
            dataFields = [dataFields[0]]
        }
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

        // the trees, grouped once so the node UUIDs every archive references are the same ones — and shared **by
        // value path** across the groupings, the way Numbers shares them (its node UUIDs are derived from the
        // path; ours are random but consistent, which a rewritten specimen proved is the whole contract)
        let allRows = Array(1...Swift.max(1, columns.first?.values.count ?? 1))
        var pathUIDs = NumbersPivot.PathUIDs()
        let rowTree = NumbersPivot.group(allRows, by: rowFields.map { columns[$0] }, uids: &pathUIDs)
        let columnTree = NumbersPivot.group(allRows, by: columnFields.map { columns[$0] }, uids: &pathUIDs)

        // the summary itself
        let laid = NumbersPivot.layout(pivot, source: columns, named: pivot.name,
                                       rowFields: rowFields, columnFields: columnFields, dataFields: dataFields,
                                       rowTree: rowTree, columnTree: columnTree, allRows: allRows)

        // The identities every CATEGORY_REF names, derived before the grid is packed because the body cells
        // carry theirs from the start. The number the whole family is counted from is the summary table's **own
        // identifier** — the `table_id` a cross-table reference names it by — and not the base owner the
        // calculation engine happens to hold: in a document Numbers wrote those are the same value, in one this
        // writer builds they are unrelated, and every UUID derived from the wrong one points nowhere (B.19).
        let summaryBase = (doc.object(summaryModel)?.string("table_id")).flatMap { NumbersUUID.uuid(fromString: $0) }
            ?? baseOwnerUUID(ofTableInfo: summaryInfo)
        let sourceBase = NumbersUUID.subowner(of: summaryBase, kind: 100) ?? NumbersUUID.random().uuid
        let gbUIDs = (0...columnFields.count).map { NumbersUUID.subowner(of: sourceBase, kind: 205 + $0) ?? NumbersUUID.random().uuid }
        // column UIDs: the rules name a source column by one of these, so the map has to exist before they do
        let rowCount = (columns.first?.values.count ?? 0) + 1
        let uids = NumbersPivot.columnUIDMap(count: columns.count, rowCount: rowCount)
        // one CATEGORY_REF per cell, resolved from the layout's spec — which grouping, at which level, at which node
        func categoryFormula(_ spec: NumbersPivot.FormulaSpec) -> ProtoMessage? {
            guard gbUIDs.indices.contains(spec.gbOffset), dataFields.indices.contains(spec.field) else { return nil }
            let node = spec.pathKey.flatMap { pathUIDs.uid(forKey: $0) } ?? NumbersPivot.axisSentinel
            return NumbersPivot.categoryFormula(groupByUID: gbUIDs[spec.gbOffset],
                                                columnUID: uids.columns[dataFields[spec.field].field],
                                                aggregateType: NumbersPivot.aggType(dataFields[spec.field].function),
                                                level: spec.level, groupUID: node)
        }
        // **The body cells keep their computed values and carry no formula.** A document Numbers wrote puts a
        // CATEGORY_REF in every body cell, and the layout's law spells them — but in a document this writer
        // builds they evaluate to nothing under the load-time recalculation the old-version template forces,
        // and a cell whose formula evaluates to nothing draws blank, wiping the value that was there. First
        // measured in B.19 on one shape; re-measured on every shape after the multi-level rewrite — body values
        // gone, totals intact — so the decision stands (Appendix B.28).
        let size = try patch(tableInfo: summaryInfo, with: laid.table, name: pivot.name, sheetName: sheetName)
        doc.update(summaryModel) { m in
            m.set("number_of_header_rows", int: laid.headerRows)
            m.set("number_of_header_columns", int: laid.headerColumns)
        }
        let file = doc.locations[sourceModel]?.0 ?? "Index/Tables/Tile.iwa"
        let uidMapID = try doc.add(uids.map, file: file)
        registerComponent(uidMapID, like: sourceModel)
        doc.update(sourceModel) { m in
            m.set("base_column_row_uids", reference: uidMapID)
            m.set("pivot_value_types_by_col", ints: columns.indices.map { i in
                dataFields.contains { $0.field == i } ? NumbersPivot.valueTypeAggregate : NumbersPivot.valueTypeGrouping
            })
        }

        // What groups there are: one group-by per column-field prefix — the first walks every column field and
        // then every row field, each further one drops the innermost remaining column field, and the last walks
        // the row fields alone (so with no column fields there is exactly one). Measured off documents Numbers
        // wrote for every shape: one column field gives the familiar pair (205, 206), two give three (205, 206,
        // 207 — the last with no columns at all, carrying the grand-total lane), none gives one (Appendix B.28).
        // The **first** is the group-by the cloned table already carries: it is registered with the calculation
        // engine and its table info already names its UUID, and a group-by the engine does not own is a group-by
        // Numbers does not read.
        guard let sourceCategoryID = doc.object(sourceModel)?.reference("category_owner"),
              let existing = doc.object(sourceCategoryID)?.references("group_by").first else {
            throw SheetError.malformedPart(path: "empty.numbers", detail: "the template's table has no category owner to make a pivot from")
        }
        // In a document Numbers wrote, the copy of the source is not a table in its own right: its dependency
        // owner is a **child of the pivot's own** (kind 100, based on the summary's base owner), and its group-bys
        // hang off that. Ours arrives as an independent clone, so it is re-parented here (Appendix B.19).
        try registerOwner(uid: sourceBase, kind: 100, base: summaryBase)

        // The grouping-column pairs: a field's `grouping_column_uid` is the UID of the summary lane its labels
        // are drawn along — its own label column for a row field, its own heading row for a column field — and
        // the same value goes on the rules and on every group-by that walks the field (Appendix B.19; measured
        // per-field on the multi-level documents, so two row fields carry two distinct UIDs).
        func rowPair(_ l: Int) -> NumbersPivot.GroupColumn {
            NumbersPivot.GroupColumn(columnUID: uids.columns[rowFields[l]], groupingUID: laid.rowGroupingUIDs[l])
        }
        func columnPair(_ l: Int) -> NumbersPivot.GroupColumn {
            NumbersPivot.GroupColumn(columnUID: uids.columns[columnFields[l]], groupingUID: laid.columnGroupingUIDs[l])
        }
        let rowPairs = rowFields.indices.map(rowPair)
        let columnPairs = columnFields.indices.map(columnPair)
        // every summarised value: each group-by caches an aggregator per value, in its own coordinate block
        let aggregates = dataFields.map { (column: columns[$0.field], uid: uids.columns[$0.field], function: $0.function) }

        // One group-by per column-field prefix. The UUIDs are the copy's counted on by 205, 206, … because those
        // are the UUIDs Numbers *computes* when it looks the group-bys up; whatever is written down is discarded
        // (Appendix B.19, `NumbersUUID.subowner`).
        var sourceGroupByIDs: [Int] = []
        for j in 0...columnFields.count {
            let keptColumns = columnFields.count - j
            let pairs = columnPairs.prefix(keptColumns) + rowPairs
            let tree: [NumbersPivot.GroupNode]
            if keptColumns == 0 {
                tree = rowTree
            } else {
                let fields = columnFields.prefix(keptColumns) + rowFields
                tree = NumbersPivot.group(allRows, by: fields.map { columns[$0] }, uids: &pathUIDs)
            }
            let archive = NumbersPivot.groupBy(columns: Array(pairs), nodes: tree, allRows: allRows,
                                               ownerIndex: 205 + j, uid: gbUIDs[j],
                                               aggregates: aggregates, rowUIDs: uids.rows)
            if j == 0 {
                // the group-by the cloned table already carries: registered with the engine, named by the info
                doc.update(existing) { $0 = archive }
                sourceGroupByIDs.append(existing)
            } else {
                let id = try doc.add(archive, file: file)
                registerComponent(id, like: sourceModel)
                try registerOwner(uid: gbUIDs[j], kind: 205 + j, base: sourceBase)
                sourceGroupByIDs.append(id)
            }
        }
        // Numbers writes each group tree **twice**: inline on the group-by, and again as one archive per node
        // chained by `child_ref`. A document Numbers made from the same workbook carries fifteen of them for two
        // group-bys. The same goes for the cached summing. Both are written here, the way it writes them.
        for id in sourceGroupByIDs {
            let file = doc.locations[id]?.0 ?? "Index/Tables/Tile.iwa"
            if let root = doc.object(id)?.message("group_node_root") {
                let rootID = try materialise(root, file: file, like: sourceModel)
                doc.update(id) { $0.set("group_node_root_ref", reference: rootID) }
            }
            let aggregators = doc.object(id)?.messages("aggregator") ?? []
            var aggregatorIDs: [Int] = []
            for aggregator in aggregators {
                let aggID = try doc.add(aggregator, file: file)
                registerComponent(aggID, like: sourceModel)
                aggregatorIDs.append(aggID)
            }
            if !aggregatorIDs.isEmpty {
                doc.update(id) { $0.set("aggregator_ref", references: aggregatorIDs) }
            }
        }
        doc.update(sourceCategoryID) { $0.set("group_by", references: sourceGroupByIDs) }
        // The clone brings the template's deprecated category owner along, group-by and all. A document Numbers
        // wrote has none on the copy of a source, and leaving a second, stale list of groups beside the real one
        // is asking Numbers which to believe.
        doc.update(sourceModel) { $0.remove("category_owner_deprecated") }
        // The clone comes with the template's summary group-by, whose kind is 8. On the copy of a source the
        // group-bys are kinds 205, 206, … — measured off documents Numbers made from the same workbooks — and
        // their UUIDs are the copy's counted on by those numbers, which is the whole of why the summary draws:
        // Numbers computes the UUID it expects rather than reading the one written down (Appendix B.19).
        try registerOwner(uid: gbUIDs[0], kind: 205, base: sourceBase, replacingExisting: true)

        // The summary keeps the empty, disabled group-by its clone came with — which is exactly what the summary
        // of a pivot carries in a document Numbers wrote.
        let summaryFile = doc.locations[summaryModel]?.0 ?? file

        // The clone brings a table's ordinary furniture with it, and a pivot's two models carry none of it in a
        // document Numbers wrote: no frozen or repeating headers, no style preset, and — the one that matters —
        // no `row_filter_set_pre_pivot`, which is where a table remembers the filtering it had *before* it became
        // a pivot. A pivot that inherits one shows the rows that survive it, and the template's shows none.
        for model in [summaryModel, sourceModel] {
            doc.update(model) { m in
                for field in ["row_filter_set_pre_pivot", "header_rows_frozen", "header_columns_frozen",
                              "repeating_header_rows_enabled", "repeating_header_columns_enabled",
                              "table_style_preset"] {
                    m.remove(field)
                }
            }
        }

        // Both models of a pivot carry a spill owner in a document Numbers wrote — the owner a formula whose
        // result runs past its own cell reports into. A pivot has none, but the field is not optional in
        // practice: a model without it is one Numbers does not finish reading (Appendix B.19).
        for model in [summaryModel, sourceModel] {
            let uid = NumbersUUID.random().uuid
            var spill = ProtoMessage(typeName: "TSCE.SpillOwnerArchive")
            spill.set("owner_uid", message: uid)
            doc.update(model) { $0.set("spill_owner", message: spill) }
            try registerOwner(uid: uid, kind: 12, base: model == summaryModel ? summaryBase : sourceBase)
        }

        // the rules
        let optionsID = try doc.add(ProtoMessage(typeName: "TST.PivotGroupingColumnOptionsMapArchive"), file: summaryFile)
        registerComponent(optionsID, like: summaryModel)
        // the pivot names the table it was made from — the one on the source sheet, not the copy it reads
        let originalInfo = (firstTableInfo[pivot.cache.sourceSheet] ?? nil) ?? sourceInfo
        let originalName = (doc.object(originalInfo)?.reference("tableModel")).flatMap { doc.object($0)?.string("table_name") } ?? sourceName
        let owner = NumbersPivot.pivotOwner(pivot, uid: NumbersUUID.random().uuid,
                                            sourceTableUID: baseOwnerUUID(ofTableInfo: originalInfo) ?? NumbersUUID.random().uuid,
                                            sourceTableName: originalName,
                                            rowColumns: rowPairs,
                                            columnColumns: columnPairs,
                                            aggregates: dataFields.map { (uids.columns[$0.field], $0.function) },
                                            optionsMap: optionsID,
                                            formulaStore: (doc.object(originalInfo)?.reference("tableModel"))
                                                .flatMap { tableReferenceUUID(ofTableModel: $0) }
                                                .map { NumbersPivot.formulaStore(sourceTableID: $0, columns: columns.count,
                                                                                 rows: columns.first?.values.count ?? 0) })
        let ownerID = try doc.add(owner, file: summaryFile)
        registerComponent(ownerID, like: summaryModel)
        doc.update(summaryModel) { $0.set("pivot_owner", reference: ownerID) }
        if let ownerUID = owner.message("pivot_owner_uid") {
            try registerOwner(uid: ownerUID, kind: 17, base: summaryBase, replacingExisting: true)
        }

        // …and the table info that says the two models are one pivot
        // The summary's grid: the label lanes carry the layout's grouping UIDs and the caption constant, a lane
        // that draws a group carries **that group's own UUID** — the join Numbers reads the pivot through — and
        // a lane that belongs to no group carries the sentinel, as many times as there are such lanes (a pivot
        // Numbers wrote with rows only and two summarised values has the sentinel twice over in its columns).
        // A fresh UUID there is a lane nothing owns, and everything on that axis draws blank (Appendix B.19).
        let summaryUIDsID = try doc.add(NumbersPivot.uidMap(columns: laid.gridColumnUIDs, rows: laid.gridRowUIDs),
                                        file: doc.locations[summaryModel]?.0 ?? "Index/Tables/Tile.iwa")
        registerComponent(summaryUIDsID, like: summaryModel)
        doc.update(summaryModel) { $0.set("base_column_row_uids", reference: summaryUIDsID) }

        // The aggregate formulas the summary's total-lane cells are drawn through (Appendix B.19 / B.28): one
        // CATEGORY_REF per cell, resolved from the layout's spec — which grouping, at which level, at which node.
        // the third model: the subtotal and grand-total lanes, and the two maps that let Numbers place them
        try fillSummaryModel(tableInfo: summaryInfo, tableModel: summaryModel, base: summaryBase,
                             cells: laid.cells, displayColumns: laid.displayColumnUIDs,
                             displayRows: laid.displayRowUIDs, formula: categoryFormula)

        // **The body cells keep their computed values and carry no formula.** A document Numbers wrote puts a
        // `CATEGORY_REF` formula in each of them, and this writer used to as well — byte-for-byte the same shape,
        // naming the same group-by, the same level and the same leaf. In ours they evaluate to nothing, and a cell
        // whose formula evaluates to nothing draws blank, wiping out the value that was already there: every body
        // cell came up empty while the totals were right. Written without them, the summary draws in full and every
        // number matches (measured on Numbers 15.3.1). Why the same formula computes there and not here is not
        // settled; what is settled is that the value is what a reader needs and the formula is what loses it
        // (Appendix B.19).

        let orderMapID = try doc.add(NumbersPivot.uidMap(columns: laid.orderColumnUIDs, rows: laid.orderRowUIDs),
                                     file: summaryFile)
        registerComponent(orderMapID, like: summaryModel)
        var order = ProtoMessage(typeName: "TST.PivotOrderArchive")
        order.set("uid_map", reference: orderMapID)
        let orderID = try doc.add(order, file: summaryFile)
        registerComponent(orderID, like: summaryModel)
        doc.update(summaryInfo) { m in
            m.set("is_a_pivot_table", bool: true)
            m.set("pivot_data_model", reference: sourceModel)
            m.set("pivot_order", reference: orderID)
            // view_column_row_uids is NOT the axis map: it is the displayed grid — the summary's lanes plus the
            // total-lane sentinel, in display order — and fillSummaryModel has already written it. The axis-shaped
            // map that used to be set here is what left the display two lanes wide (Appendix B.19).
        }
        // The copy of the source is reached through the pivot, never through the sheet — and in the engine it is
        // **not a table at all**: the reference document gives it no TableInfo and no base owner, and hangs its
        // haunted owner straight off the pivot's kind-100 owner. A copy that keeps its cloned table identity is a
        // model with two owners, and the pivot's binding of it loses to the ghost: Numbers computes every total
        // and draws no groups (Appendix B.19).
        doc.update(sid) { m in
            let remaining = m.references("drawable_infos").filter { $0 != sourceInfo }
            m.set("drawable_infos", references: remaining)
        }
        var copyBaseUID: String?
        var ghostOwnerID: Int?
        for fid in doc.identifiers(ofType: "TSCE.FormulaOwnerDependenciesArchive") {
            guard let f = doc.object(fid), f.reference("formula_owner") == sourceInfo else { continue }
            copyBaseUID = NumbersUUID.hex(f.message("formula_owner_uid"))
            ghostOwnerID = fid
            break
        }
        if let ghost = copyBaseUID {
            for fid in doc.identifiers(ofType: "TSCE.FormulaOwnerDependenciesArchive") {
                guard let f = doc.object(fid), NumbersUUID.hex(f.message("base_owner_uid")) == ghost else { continue }
                doc.update(fid) { $0.set("base_owner_uid", message: sourceBase) }
            }
        }
        if let ghostOwnerID {
            doc.update(calcEngineID) { engine in
                var tracker = engine.message("dependency_tracker") ?? ProtoMessage(typeName: "TSCE.DependencyTrackerArchive")
                let kept = tracker.references("formula_owner_dependencies").filter { $0 != ghostOwnerID }
                tracker.remove("formula_owner_dependencies")
                for r in kept { tracker.append("formula_owner_dependencies", reference: r) }
                engine.set("dependency_tracker", message: tracker)
            }
            doc.remove(ghostOwnerID)
        }
        // SPIKE: the clone's scaffolding — its TableInfo, caption, own summary model and category order — deleted
        // as one island, so the data copy has a single owner the way the reference document's has. Measured to
        // clear the integrity problems and the "table corruption" audit; it does not by itself make Numbers draw.
        deleteCloneScaffolding(tableInfo: sourceInfo)

        // The formula spaces the reference registers on the pivot family and this writer had nowhere. Which UID
        // carries which kind was measured by searching the reference's models for every registered owner's UID
        // (Appendix B.19):
        //   kind 8  = the summary's group-by UUID (`TableInfo.group_by_uuid`)
        //   kind 17 = **the pivot owner's own uid** — the rules; unregistered rules bind no axes and draw no groups
        //   kind 4  = a model's hidden-states owner, kind 11 = its column hidden-state extent
        //   kinds 3, 5, 6, 10 = free per-table spaces nothing in the models names
        if let groupByUUID = doc.object(summaryInfo)?.message("group_by_uuid") {
            try registerOwner(uid: groupByUUID, kind: 8, base: summaryBase, replacingExisting: true)
        }
        for (model, base) in [(summaryModel, summaryBase), (sourceModel, sourceBase as ProtoMessage?)] {
            if let hidden = doc.object(model)?.message("hidden_states_owner") {
                if let uid = hidden.message("owner_uid") {
                    try registerOwner(uid: uid, kind: 4, base: base, replacingExisting: true)
                }
                if let extent = hidden.message("hidden_states")?.message("column_hidden_state_extent"),
                   let uid = extent.message("hidden_state_extent_uid") {
                    try registerOwner(uid: uid, kind: 11, base: base, replacingExisting: true)
                }
            }
            for kind in [3, 5, 6, 10] {
                try registerOwner(uid: NumbersUUID.random().uuid, kind: kind, base: base)
            }
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

    /// Deletes a clone's scaffolding once its model has been taken over as the pivot's data copy: the island of
    /// objects reachable from `tableInfo` that nothing outside the island references. Membership is decided by
    /// the document, not by a list of fields — an object the rest of the document still names (the model itself,
    /// the sheet, a shared standin caption) leaves the island, and everything it reaches leaves with it, so no
    /// survivor is left back-referencing a deleted object.
    private mutating func deleteCloneScaffolding(tableInfo: Int) {
        var reach: Set<Int> = []
        var queue = [tableInfo]
        while let id = queue.popLast() {
            guard reach.insert(id).inserted, let obj = doc.object(id) else { continue }
            queue.append(contentsOf: obj.allReferences())
        }
        var referrers: [Int: Set<Int>] = [:]
        for id in doc.locations.keys {
            for r in doc.object(id)?.allReferences() ?? [] where id != r { referrers[r, default: []].insert(id) }
        }
        var island = reach
        var changed = true
        while changed {
            changed = false
            for id in Array(island) where !(referrers[id] ?? []).isSubset(of: island) {
                island.remove(id)
                changed = true
            }
        }
        for id in island { doc.remove(id) }
        // components for these objects may still be queued — flushComponents runs after the pivots — and the
        // clone machinery has already written identity-map entries for them; both would resurrect the deleted
        pendingComponents.removeAll { island.contains($0.new) }
        doc.update(NumbersDocument.packageID) { pkg in
            var comps = pkg.messages("components")
            for i in comps.indices {
                let kept = comps[i].messages("object_uuid_map_entries").filter { !island.contains($0.int("identifier") ?? -1) }
                guard kept.count != comps[i].messages("object_uuid_map_entries").count else { continue }
                comps[i].remove("object_uuid_map_entries")
                for e in kept { comps[i].append("object_uuid_map_entries", message: e) }
            }
            pkg.set("components", messages: comps)
        }
    }

    /// A UUID the writer invented, made known to the calculation engine. A group-by whose UUID no owner claims is
    /// one Numbers does not read (Appendix B.19); the clone machinery mints these for the objects it copies, and
    /// this does the same for the ones a pivot adds.
    private mutating func registerOwner(uid: ProtoMessage, kind: Int, base: ProtoMessage?,
                                        replacingExisting: Bool = false) throws {
        if replacingExisting, let hex = NumbersUUID.hex(uid) {
            for fid in doc.identifiers(ofType: "TSCE.FormulaOwnerDependenciesArchive")
            where NumbersUUID.hex(doc.object(fid)?.message("formula_owner_uid")) == hex {
                doc.update(fid) { m in
                    m.set("owner_kind", int: kind)
                    if let base { m.set("base_owner_uid", message: base) }
                }
                return
            }
        }
        guard let file = doc.locations[calcEngineID]?.0 else { return }
        var owner = ProtoMessage(typeName: "TSCE.FormulaOwnerDependenciesArchive")
        owner.set("formula_owner_uid", message: uid)
        owner.set("owner_kind", int: kind)
        if let base { owner.set("base_owner_uid", message: base) }
        // The eight dependency containers, empty. Every owner in a document Numbers wrote carries exactly this
        // set whether or not anything is in them, and a bare owner without them poisons the document outright —
        // adding one to a working document made Numbers refuse it whole (Appendix B.19).
        for (field, type) in [("volatile_dependencies", "TSCE.VolatileDependenciesExpandedArchive"),
                              ("spanning_column_dependencies", "TSCE.SpanningDependenciesExpandedArchive"),
                              ("spanning_row_dependencies", "TSCE.SpanningDependenciesExpandedArchive"),
                              ("cell_errors", "TSCE.CellErrorsArchive"),
                              ("tiled_cell_dependencies", "TSCE.CellDependenciesTiledArchive"),
                              ("uuid_references", "TSCE.UuidReferencesArchive"),
                              ("tiled_range_dependencies", "TSCE.RangeDependenciesTiledArchive"),
                              ("spill_range_sizes", "TSCE.CellSpillSizesArchive")] {
            owner.set(field, message: ProtoMessage(typeName: type))
        }
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

    /// The pivot's third model. `TST.TableInfoArchive.summary_model` names a `TST.SummaryModelArchive` with a
    /// data store of its own, and that store is where the grand-total lane lives — the caption, one total per
    /// displayed row and column, and the grand total. The stored grid is exactly axes-sized; the total lanes
    /// exist only here (read off the reference document's tile: `総計` + 12/15/9 + 16/20/36, Appendix B.19).
    ///
    /// Alongside the cells go the two maps that place them: the summary model's own UID map — the grid's UIDs
    /// **plus the label-lane sentinel**, which in this space stands for the total row and column — and the table
    /// info's `view_column_row_uids`, the same set in display order. The clone arrives with the template's empty
    /// store and an unrelated view map, which is why the pivot drew as an empty shell for so long.
    private mutating func fillSummaryModel(tableInfo: Int, tableModel: Int, base: ProtoMessage?,
                                           cells: [NumbersPivot.SummaryCell],
                                           displayColumns: [ProtoMessage], displayRows: [ProtoMessage],
                                           formula: (NumbersPivot.FormulaSpec) -> ProtoMessage?) throws {
        guard let info = doc.object(tableInfo), let summaryID = info.reference("summary_model"),
              var summary = doc.object(summaryID), var store = summary.message("data_store") else { return }
        let file = doc.locations[summaryID]?.0 ?? "Index/Tables/Tile.iwa"

        // The two maps — the summary model's own and the info's view map — both hold **every displayed lane**:
        // the header lanes, a lane per group node (each group's own subtotal lane right after its members), and
        // the grand-total lanes last. An axis with no group fields has no appended total lane: its body lanes
        // are the total already (Appendix B.19 / B.28).
        let columns = displayColumns
        let rows = displayRows
        let map = NumbersPivot.uidMap(columns: columns, rows: rows)
        if let existing = summary.reference("column_row_uids") {
            doc.replace(existing, with: map)
        } else {
            let id = try doc.add(map, file: file)
            registerComponent(id, like: summaryID)
            summary.set("column_row_uids", reference: id)
        }
        if let viewID = info.references("view_column_row_uids").first {
            doc.replace(viewID, with: map)
        } else {
            // the template's info carries no view map at all, so replacing in place is a silent no-op — the one
            // missing link that kept the display two lanes wide after everything else was tied (Appendix B.19)
            let viewID = try doc.add(map, file: file)
            registerComponent(viewID, like: summaryID)
            doc.update(tableInfo) { $0.set("view_column_row_uids", reference: viewID) }
        }

        // the aggregate space the total cells conceptually live in (owner kind 9, measured)
        let aggregateUID = summary.message("aggregate_formula_owner_uuid") ?? NumbersUUID.random().uuid
        summary.set("aggregate_formula_owner_uuid", message: aggregateUID)
        try registerOwner(uid: aggregateUID, kind: 9, base: base)

        // a vendor of our own: the clone shares the template's, whose back-reference names the template's table
        var vendor = ProtoMessage(typeName: "TST.SummaryCellVendorArchive")
        vendor.set("table_info", reference: tableInfo)
        let vendorID = try doc.add(vendor, file: file)
        registerComponent(vendorID, like: summaryID)
        summary.set("summary_cell_vendor", reference: vendorID)

        // the total cells, sparse, into the summary's own store
        var strings: [String: Int] = [:]
        var stringEntries: [ProtoMessage] = []
        func stringKey(_ text: String) -> Int {
            if let k = strings[text] { return k }
            let k = stringEntries.count + 1
            var e = ProtoMessage(typeName: "TST.TableDataList.ListEntry")
            e.set("key", int: k); e.set("string", string: text); e.set("refcount", int: 1)
            stringEntries.append(e); strings[text] = k
            return k
        }
        let columnCount = columns.count
        var byRow: [Int: [Int: Data]] = [:]
        var formulaEntries: [ProtoMessage] = []
        func formulaKey(_ cell: NumbersPivot.SummaryCell) -> Int? {
            guard let spec = cell.formula, let f = formula(spec) else { return nil }
            let key = formulaEntries.count + 1
            var e = ProtoMessage(typeName: "TST.TableDataList.ListEntry")
            e.set("key", int: key); e.set("refcount", int: 1)
            e.set("formula", message: f)
            formulaEntries.append(e)
            return key
        }
        for cell in cells {
            let record: Data
            switch cell.value {
            case .text(let t): record = CellStorage.encode(type: .text, stringID: stringKey(t))
            case .number(let d): record = CellStorage.encode(type: .number, decimal: d, double: (d as NSDecimalNumber).doubleValue,
                                                             formulaID: formulaKey(cell))
            case .integer(let i): record = CellStorage.encode(type: .number, decimal: Decimal(i), double: Double(i),
                                                              formulaID: formulaKey(cell))
            default: continue
            }
            byRow[cell.row, default: [:]][cell.col] = record
        }
        if let sid = store.reference("stringTable") {
            let entries = stringEntries
            doc.update(sid) { list in
                list.set("entries", messages: entries)
                list.set("nextListID", int: entries.count + 1)
            }
        }
        if let fid = store.reference("formula_table") {
            let entries = formulaEntries
            doc.update(fid) { list in
                list.set("entries", messages: entries)
                list.set("nextListID", int: entries.count + 1)
            }
        }
        var tile = ProtoMessage(typeName: "TST.Tile")
        tile.set("maxColumn", int: 0); tile.set("maxRow", int: 0); tile.set("numCells", int: 0)
        tile.set("numrows", int: rows.count)
        tile.set("storage_version", int: 5); tile.set("last_saved_in_BNC", bool: true); tile.set("should_use_wide_rows", bool: true)
        var infos: [ProtoMessage] = []
        for row in byRow.keys.sorted() {
            var rowInfo = ProtoMessage(typeName: "TST.TileRowInfo")
            rowInfo.set("tile_row_index", int: row)
            var storage = Data(), offsets = [Int16](repeating: -1, count: columnCount), count = 0
            for col in 0..<columnCount {
                guard let record = byRow[row]?[col] else { continue }
                offsets[col] = Int16(storage.count >> 2)
                storage.append(record)
                count += 1
            }
            rowInfo.set("cell_count", int: count)
            var offsetBytes = Data()
            for o in offsets { let u = UInt16(bitPattern: o); offsetBytes.append(UInt8(u & 0xFF)); offsetBytes.append(UInt8(u >> 8)) }
            rowInfo.set("cell_offsets", bytes: offsetBytes)
            rowInfo.set("cell_offsets_pre_bnc", bytes: NumbersWriter.preBNCBytes)
            rowInfo.set("storage_version", int: 5)
            rowInfo.set("cell_storage_buffer", bytes: storage)
            rowInfo.set("cell_storage_buffer_pre_bnc", bytes: NumbersWriter.preBNCBytes)
            rowInfo.set("has_wide_offsets", bool: true)
            infos.append(rowInfo)
        }
        tile.set("rowInfos", messages: infos)
        // The header buckets stay as the clone left them: the reference document also opens and draws with the
        // summary model's buckets emptied, and writing headers here — however faithfully — made Numbers refuse
        // the package outright. Measured both ways (Appendix B.19).
        for old in store.message("tiles")?.messages("tiles").compactMap({ $0.reference("tile") }) ?? [] {
            doc.remove(old)
            // the clone queued a component for the tile it copied; a component for an object that no longer
            // exists is a package Numbers refuses to open (-43)
            pendingComponents.removeAll { $0.new == old }
        }
        let tileID = try doc.add(tile, file: "Index/Tables/Tile-{id}.iwa")
        registerTileComponent(tileID)
        var tileStorage = store.message("tiles") ?? ProtoMessage(typeName: "TST.TileStorage")
        tileStorage.remove("tiles")
        tileStorage.set("tile_size", int: NumbersWriter.tileSize)
        var ref = ProtoMessage(typeName: "TST.TileStorage.Tile")
        ref.set("tileid", int: 0); ref.set("tile", reference: tileID)
        tileStorage.set("tiles", messages: [ref])
        store.set("tiles", message: tileStorage)
        summary.set("data_store", message: store)
        doc.replace(summaryID, with: summary)
    }

    private func rowsOfColumnLeaf(_ index: Int, firstTree: [NumbersPivot.GroupNode]) -> Set<Int> {
        firstTree.indices.contains(index) ? Set(firstTree[index].rows) : []
    }

    /// Lays a group tree down as archives — one per node, children reached by `child_ref` instead of being nested
    /// inside their parent. Returns the root's identifier (Appendix B.19).
    private mutating func materialise(_ node: ProtoMessage, file: String, like sibling: Int) throws -> Int {
        var copy = node
        let children = node.messages("child")
        copy.remove("child")
        var childIDs: [Int] = []
        for child in children { childIDs.append(try materialise(child, file: file, like: sibling)) }
        if !childIDs.isEmpty { copy.set("child_ref", references: childIDs) }
        let id = try doc.add(copy, file: file)
        registerComponent(id, like: sibling)
        return id
    }

    /// Moves an existing dependency owner under another base — the copy of a source belongs to the pivot that
    /// reads it, not to a table of its own.
    private func rebaseOwner(of uid: ProtoMessage, onto base: ProtoMessage, kind: Int? = nil) {
        guard let hex = NumbersUUID.hex(uid) else { return }
        for fid in doc.identifiers(ofType: "TSCE.FormulaOwnerDependenciesArchive") {
            guard NumbersUUID.hex(doc.object(fid)?.message("formula_owner_uid")) == hex else { continue }
            doc.update(fid) {
                $0.set("base_owner_uid", message: base)
                if let kind { $0.set("owner_kind", int: kind) }
            }
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
                                conditionalFormats: [ConditionalFormatting] = [],
                                popupRules: [(rule: DataValidation, items: [String])] = []) throws -> (width: Double, height: Double) {
        guard let modelID = doc.object(tableInfo)?.reference("tableModel"), var model = doc.object(modelID), var store = model.message("base_data_store") else {
            throw SheetError.malformedPart(path: "empty.numbers", detail: "table model missing")
        }
        // A pop-up menu exists only on cells the table has, so the grid grows to carry a rule over empty entry
        // rows — that is what a dropdown on a form is. Only a rule of a *form's* size does that: the common Excel
        // shape is a dropdown over a whole column, a million rows, and a table that answers it draws a million
        // rows. Anything reaching past 10,000 rows or 256 columns stops at the table's edge instead, the way
        // Numbers itself cuts a whole-column rule when it imports one (measured), and the cut is reported below.
        let formRanges = popupRules.flatMap(\.rule.ranges.ranges).filter { $0.maxRow < 10_000 && $0.maxCol < 256 }
        let rows = Swift.max(1, Swift.max(table.rowCount, table.nextAppendRow, (table.rowDimensions.keys.max() ?? -1) + 1,
                                          (table.merges.map(\.maxRow).max() ?? -1) + 1, (formRanges.map(\.maxRow).max() ?? -1) + 1))
        let cols = Swift.max(1, Swift.max(table.columnCount, (table.columnDimensions.keys.max() ?? -1) + 1,
                                          (table.merges.map(\.maxCol).max() ?? -1) + 1, (formRanges.map(\.maxCol).max() ?? -1) + 1))
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

        // pop-up menus: each inline list rule becomes one menu, an entry of the table's control list, and a key on
        // every covered cell. The menu lives in the list's own component, the way Numbers places it. The grid was
        // grown above to carry a form-sized rule; what still reaches past it is cut at the edge, and reported.
        let controlList = store.reference("control_cell_spec_table")
        var controlEntries: [ProtoMessage] = []
        var controlKeys: [CellRef: Int] = [:]
        var clippedRules = 0
        let controlledCells = table.cells.filter { $0.value.control != nil && $0.key.row < rows && $0.key.col < cols && !covered.contains($0.key) }
        if !popupRules.isEmpty || !controlledCells.isEmpty, controlList == nil {
            warnings.append(ConversionWarning(.dropped, subject: .formatting, sheet: sheetName,
                                              message: "\(popupRules.count + controlledCells.count) validation rule(s) / cell control(s) dropped: the template's table has no control list"))
        }
        if let listID = controlList {
            let controlFile = doc.locations[listID]?.0 ?? NumbersStyleWriter.stylesheetFile
            for (rule, items) in popupRules {
                var menu = ProtoMessage(typeName: "TST.PopUpMenuModel")
                menu.set("tsce_item", messages: [NumbersWriter.popupChoice(nil)] + items.map { NumbersWriter.popupChoice($0) })
                let menuID = try doc.add(menu, file: controlFile)
                var spec = ProtoMessage(typeName: "TST.CellSpecArchive")
                spec.set("interaction_type", int: NumbersWriter.popupInteractionType)
                spec.set("chooser_control_popup_model", reference: menuID)
                spec.set("chooser_control_start_w_first", bool: true)
                let key = controlEntries.count + 1
                var entry = ProtoMessage(typeName: "TST.TableDataList.ListEntry")
                entry.set("key", int: key); entry.set("refcount", int: 0); entry.set("cell_spec", message: spec)
                controlEntries.append(entry)
                var clipped = false
                for range in rule.ranges.ranges {
                    if range.maxRow >= rows || range.maxCol >= cols { clipped = true }
                    for r in range.minRow...range.maxRow where r < rows {
                        for c in range.minCol...range.maxCol where c < cols {
                            controlKeys[CellRef(row: r, col: c)] = key
                        }
                    }
                }
                if clipped { clippedRules += 1 }
            }

            // the cells' own controls: checkbox, stepper, slider, star rating (Appendix B.25). Cells wearing the
            // same control share one entry, the way Numbers shares them. A control edits a value of its own kind —
            // a checkbox a boolean, a dial a number — so a cell whose value is neither keeps the value and loses
            // the control, out loud.
            var controlEntryKeys: [CellControl: Int] = [:]
            var overlappingControls = 0
            var mismatchedControls: [CellRef] = []
            for (ref, cell) in controlledCells.sorted(by: { ($0.key.row, $0.key.col) < ($1.key.row, $1.key.col) }) {
                guard let control = cell.control else { continue }
                let fits: Bool
                switch cell.value {
                case nil: fits = true
                case .bool: fits = control.kind == .checkbox
                case .integer, .number: fits = control.kind != .checkbox
                default: fits = false
                }
                guard fits else { mismatchedControls.append(ref); continue }
                if controlKeys[ref] != nil { overlappingControls += 1 }
                let key: Int
                if let existing = controlEntryKeys[control] {
                    key = existing
                } else {
                    var spec = ProtoMessage(typeName: "TST.CellSpecArchive")
                    spec.set("interaction_type", int: NumbersWriter.controlInteractionTypes[control.kind]!)
                    if control.kind != .checkbox {
                        spec.set("range_control_min", double: control.minimum)
                        spec.set("range_control_max", double: control.maximum)
                        spec.set("range_control_inc", double: control.increment)
                    }
                    key = controlEntries.count + 1
                    var entry = ProtoMessage(typeName: "TST.TableDataList.ListEntry")
                    entry.set("key", int: key); entry.set("refcount", int: 0); entry.set("cell_spec", message: spec)
                    controlEntries.append(entry)
                    controlEntryKeys[control] = key
                }
                controlKeys[ref] = key
            }
            if let first = mismatchedControls.first {
                warnings.append(ConversionWarning(.degraded, subject: .other, sheet: sheetName, location: first,
                                                  message: "\(mismatchedControls.count) cell control(s) dropped: a checkbox edits a boolean and a dial edits a number, and the cell's value is neither — the value wins"))
            }
            if overlappingControls > 0 {
                warnings.append(ConversionWarning(.degraded, subject: .formatting, sheet: sheetName,
                                                  message: "a list rule and a cell control met on \(overlappingControls) cell(s); the cell's own control wins"))
            }

            for i in controlEntries.indices {
                let key = controlEntries[i].int("key") ?? 0
                controlEntries[i].set("refcount", int: controlKeys.values.filter { $0 == key }.count)
            }
        }
        if clippedRules > 0 {
            warnings.append(ConversionWarning(.degraded, subject: .formatting, sheet: sheetName,
                                              message: "\(clippedRules) pop-up menu rule(s) reach past the table and stop at its edge (Numbers cuts an imported whole-column rule the same way)"))
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

        // A cell with no value is not an empty cell. The model drops a truly blank one, so everything still here
        // has a reason: a fill, a border, a note, a link. A sheet draws with exactly these — a Gantt bar, a
        // weekend column, a legend swatch are colour and nothing else — and skipping them here sent the drawing
        // out blank and unreported (Appendix B.20).
        for (ref, cell) in table.cells where ref.row < rows && ref.col < cols && !covered.contains(ref) {
            var value: CellValue? = cell.value
            var formulaID: Int?
            if case .formula(let expr, let cached)? = cell.value {
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
            var formatKey = style.numberFormat == NumberFormat.general ? nil : styleWriter.formatKey(for: style.numberFormat)
            // A control cell draws through its own format, and always holds a value — Numbers itself fills an
            // untouched checkbox with false, a dial with its minimum, a rating with 0 (Appendix B.25).
            if let control = cell.control, controlKeys[ref] != nil {
                switch control.kind {
                case .checkbox, .rating: formatKey = styleWriter.controlFormatKey(control.kind)
                case .stepper, .slider: if formatKey == nil { formatKey = styleWriter.controlFormatKey(control.kind) }
                }
                if value == nil {
                    switch control.kind {
                    case .checkbox: value = .bool(false)
                    case .rating: value = .integer(0)
                    case .stepper, .slider: value = .number(Decimal(control.minimum))
                    }
                }
            }
            records[ref.row][ref.col] = record(for: value, key: key, cellStyleID: keys.cell, textStyleID: keys.text,
                                               formatKey: formatKey, code: style.numberFormat, formulaID: formulaID,
                                               conditionalStyleID: conditionalKeys[ref], controlID: controlKeys[ref],
                                               richID: richID, commentID: commentID)
        }
        for i in formulaEntries.indices {
            let k = formulaEntries[i].int("key") ?? 0
            formulaEntries[i].set("refcount", int: formulaRefcounts[k] ?? 1)
        }
        // an empty cell inside a rule's range still names the rule — otherwise the rule stops at the last cell
        // that happened to hold something. The same for a pop-up menu: an empty cell wearing one is what a
        // dropdown on an entry form is.
        for ref in Set(conditionalKeys.keys).union(controlKeys.keys) where records[ref.row][ref.col] == nil {
            records[ref.row][ref.col] = CellStorage.encode(type: .generic, conditionalStyleID: conditionalKeys[ref], controlID: controlKeys[ref])
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
            pendingCrossings.append((from: sid, to: styleWriter.styleObjects))
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
            if !entries.isEmpty {
                // every style a rule names, minted or borrowed. The table's own defaults stand in for the half a
                // rule does not vary, and they live in the stylesheet component just as the minted ones do — an
                // undeclared crossing is a reference Numbers cannot resolve, and it refuses the document.
                let named = styleWriter.allStyleObjects + [styleWriter.defaultCellStyle, styleWriter.defaultTextStyle].compactMap { $0 }
                pendingCrossings.append((from: cid, to: Array(Set(named))))
            }
        } else if !conditionalEntries.isEmpty {
            warnings.append(ConversionWarning(.dropped, subject: .formatting, sheet: sheetName,
                                              message: "conditional formats dropped: the template's table has no conditional-style list"))
        }

        // control list (the pop-up menus; their entries reference menus in the list's own component, so there
        // is no crossing to declare)
        if let cid = controlList, !controlEntries.isEmpty {
            let entries = controlEntries
            doc.update(cid) { list in
                list.set("entries", messages: entries)
                list.set("nextListID", int: entries.count + 1)
            }
        }

        // rich-text and comment lists
        if let rid = richList, !richEntries.isEmpty {
            let entries = richEntries
            doc.update(rid) { list in
                list.set("entries", messages: entries)
                list.set("nextListID", int: entries.count + 1)
            }
            // everything the storage names and does not live beside it: the stylesheet, the styles a run
            // wears, the paragraph and list styles. An undeclared crossing is a document Numbers will not open.
            let named = styleWriter.allStyleObjects
                + [plainRun, linkRun, listStyle, styleWriter.stylesheetID, styleWriter.defaultTextStyle].compactMap { $0 }
            pendingCrossings.append((from: rid, to: Array(Set(named))))
        }
        if let cid = commentList, !commentEntries.isEmpty {
            let entries = commentEntries
            doc.update(cid) { list in
                list.set("entries", messages: entries)
                list.set("nextListID", int: entries.count + 1)
            }
            pendingCrossings.append((from: cid, to: Array(authorIDs.values)))
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
                                 conditionalStyleID: Int? = nil, controlID: Int? = nil, richID: Int? = nil, commentID: Int? = nil) -> Data? {
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
                                      conditionalStyleID: conditionalStyleID, formulaID: formulaID, controlID: controlID,
                                      numFormatID: number, currencyFormatID: currency, dateFormatID: date,
                                      durationFormatID: duration, textFormatID: text, boolFormatID: boolean)
        }
        switch value {
        case nil:
            // a cell whose text lives in the rich-text list, or a formula whose result the source never cached
            if richID != nil { return encode(.automatic) }
            // …or one that holds no value and is still worth a record: a style is a thing a cell says. The same
            // generic record already carries a conditional style below, so the format expresses it; what it may
            // not carry is nothing at all, which is what an untouched cell is (Appendix B.20).
            let saysSomething = formulaID != nil || commentID != nil || cellStyleID != nil || textStyleID != nil
                || conditionalStyleID != nil || controlID != nil || formatKey != nil
            return saysSomething ? encode(.generic) : nil
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
