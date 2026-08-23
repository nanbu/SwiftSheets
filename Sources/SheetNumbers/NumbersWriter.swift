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
        var sheetIDs: [Int] = []
        for (i, sheet) in workbook.sheets.enumerated() {
            let sid = i == 0 ? templateSheet : try cloneSheet()
            sheetIDs.append(sid)
            doc.update(sid) { $0.set("name", string: sheet.name) }
            if sheet.state != .visible { warnings.append(ConversionWarning(.degraded, sheet: sheet.name, message: "Numbers has no hidden sheets; the sheet is visible")) }
            if !sheet.dataValidations.isEmpty || sheet.hasUnmodelledValidations {
                warnings.append(ConversionWarning(.dropped, subject: .formatting, sheet: sheet.name, message: "data validation dropped: Numbers rules are not written"))
            }
            var infos = doc.object(sid)?.references("drawable_infos").filter { doc.typeName($0) == "TST.TableInfoArchive" } ?? []
            let tables = sheet.tables.isEmpty ? [Table()] : sheet.tables
            var y = 0.0
            for (t, table) in tables.enumerated() {
                let info: Int
                if t < infos.count { info = infos[t] } else { info = try cloneTable(from: infos[0], intoSheet: sid); infos.append(info) }
                let name = table.name ?? "Table \(t + 1)"
                let size = try patch(tableInfo: info, with: table, name: name, sheetName: sheet.name)
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
            if sheet.freezePanes != nil, tables.first?.nextAppendRow ?? 0 > 0 {
                // header rows / columns are Numbers' frozen panes
                let fp = sheet.freezePanes!
                doc.update(doc.object(infos[0])!.reference("tableModel")!) { m in
                    m.set("number_of_header_rows", int: fp.row); m.set("number_of_header_columns", int: fp.col)
                    m.set("header_rows_frozen", bool: fp.row > 0); m.set("header_columns_frozen", bool: fp.col > 0)
                }
            }
        }
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

    private func registerComponent(_ new: Int, like old: Int) {
        doc.update(NumbersDocument.packageID) { pkg in
            var comps = pkg.messages("components")
            guard let template = comps.first(where: { $0.int("identifier") == old }) else { return }
            var c = template
            c.set("identifier", int: new)
            if let loc = c.string("locator"), let preferred = c.string("preferred_locator") { c.set("locator", string: preferred + "-\(new)"); _ = loc }
            comps.append(c)
            pkg.set("components", messages: comps)
        }
        // the calculation engine component lists the table components it uses
        addExternalReference(toComponentNamed: "CalculationEngine", componentID: new, objectID: nil)
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

    // MARK: - Patching one table's data

    private mutating func patch(tableInfo: Int, with table: Table, name: String, sheetName: String) throws -> (width: Double, height: Double) {
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

        // cell records per row
        var records: [[Data?]] = Array(repeating: Array(repeating: nil, count: cols), count: rows)
        var formattedWarned = false
        for (ref, cell) in table.cells where ref.row < rows && ref.col < cols && !covered.contains(ref) {
            guard var value = cell.value else { continue }
            if case .formula(_, let cached) = value {
                warnings.append(ConversionWarning(.degraded, subject: .formulas, sheet: sheetName, location: ref, message: "formula written as its cached value (Numbers formula archives are not generated)"))
                guard let c = cached else { continue }
                value = c
            }
            if cell.style != .default, !formattedWarned {
                warnings.append(ConversionWarning(.degraded, subject: .formatting, sheet: sheetName, message: "cell formatting is not written to Numbers yet"))
                formattedWarned = true
            }
            records[ref.row][ref.col] = record(for: value, key: key)
        }
        for (ref, _) in table.cells where (ref.row >= rows || ref.col >= cols) && ref.row < 0 { _ = ref }

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

    private func registerTileComponent(_ id: Int) {
        doc.update(NumbersDocument.packageID) { pkg in
            var comps = pkg.messages("components")
            var c = ProtoMessage(typeName: "TSP.ComponentInfo")
            c.set("identifier", int: id)
            c.set("preferred_locator", string: "Tables/Tile")
            c.set("locator", string: "Tables/Tile-\(id)")
            c.set("is_stored_outside_object_archive", bool: false)
            for v in [2, 0, 0] { c.fields.append(ProtoMessage.Field(number: NumbersSchema.shared.fieldNumber("TSP.ComponentInfo", "document_read_version")!, value: .varint(UInt64(v)))) }
            for v in [2, 0, 0] { c.fields.append(ProtoMessage.Field(number: NumbersSchema.shared.fieldNumber("TSP.ComponentInfo", "document_write_version")!, value: .varint(UInt64(v)))) }
            c.set("save_token", int: 1)
            comps.append(c)
            pkg.set("components", messages: comps)
        }
        addExternalReference(toComponentNamed: "CalculationEngine", componentID: id, objectID: nil)
    }

    /// The packed record for a value (nil for kinds Numbers cannot hold, after a warning).
    private mutating func record(for value: CellValue, key: (String) -> Int) -> Data? {
        switch value {
        case .text(let s): return CellStorage.encode(type: .text, stringID: key(s))
        case .richText(let runs): return CellStorage.encode(type: .text, stringID: key(runs.map(\.text).joined()))
        case .integer(let i): return CellStorage.encode(type: .number, decimal: Decimal(i))
        case .number(let d): return CellStorage.encode(type: .number, decimal: d)
        case .bool(let b): return CellStorage.encode(type: .bool, double: b ? 1 : 0)
        case .date(let dt):
            let seconds = Double(dt.date.dayNumber - NumbersReader.epochDay) * 86400 + dt.time.dayFraction * 86400
            return CellStorage.encode(type: .date, seconds: seconds)
        case .time(let t):   // a time of day is a date on the epoch day
            return CellStorage.encode(type: .date, seconds: t.dayFraction * 86400)
        case .duration(let d):
            let (s, attos) = d.components
            return CellStorage.encode(type: .duration, double: Double(s) + Double(attos) / 1e18)
        case .error(let e): return CellStorage.encode(type: .text, stringID: key(e))
        case .formula: return nil
        }
    }
}
