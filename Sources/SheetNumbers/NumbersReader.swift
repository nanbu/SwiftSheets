import Foundation
import SheetCore

/// Document → Sheet → TableInfo → TableModel → DataStore (tiles, string / formula / rich-text lists) → the model
/// (spec §10.2). Tolerant: what cannot be interpreted becomes a warning, never a failure (§10.3).
struct NumbersReader {
    /// Days from 1970-01-01 to Numbers' epoch 2001-01-01.
    static let epochDay = CivilDate(year: 2001, month: 1, day: 1)!.dayNumber
    static let defaultRowHeight = 20.0
    static let defaultColumnWidth = 98.0
    /// Points per Excel character-width unit (Excel's default 8.43 chars ≈ 48 pt).
    static let pointsPerCharacter = 5.7

    let doc: NumbersDocument
    let options: ReadOptions
    var warnings: [ConversionWarning] = []
    private var tableUUIDToName: [String: String] = [:]

    init(doc: NumbersDocument, options: ReadOptions) { self.doc = doc; self.options = options }

    mutating func workbook() throws -> Workbook {
        guard let document = doc.object(NumbersDocument.documentID), document.typeName == "TN.DocumentArchive" else {
            throw SheetError.malformedPart(path: "Index/Document.iwa", detail: "object 1 is not a TN.DocumentArchive")
        }
        var wb = Workbook(sheets: [])
        wb.dataOnly = options.dataOnly
        wb.sourceInfo = sourceInfo()
        wb.preserved.sourceFormat = .numbers
        if let engine = doc.identifiers(ofType: "TSCE.CalculationEngineArchive").first, doc.object(engine)?.bool("base_date_1904") == true { wb.epoch = .mac1904 }

        let sheetIDs = document.references("sheets").filter { doc.typeName($0) == "TN.SheetArchive" }
        // name every table first so cross-table references can be rendered
        for sid in sheetIDs {
            let sheetName = doc.object(sid)?.string("name") ?? "Sheet"
            for tid in tableModels(inSheet: sid) {
                guard let model = doc.object(tid) else { continue }
                let name = sheetName + "::" + (model.string("table_name") ?? "Table")
                if let hex = NumbersUUID.hex(model.message("haunted_owner")?.message("owner_uid")) { tableUUIDToName[hex] = name }
            }
        }
        // FormulaOwnerDependencies map formula-owner UUIDs to base-owner UUIDs; cross references use the base owner
        for fid in doc.identifiers(ofType: "TSCE.FormulaOwnerDependenciesArchive") {
            guard let f = doc.object(fid), let owner = NumbersUUID.hex(f.message("formula_owner_uid")), let base = NumbersUUID.hex(f.message("base_owner_uid")),
                  let name = tableUUIDToName[owner] else { continue }
            tableUUIDToName[base] = name
        }

        var sheets: [Sheet] = []
        for sid in sheetIDs {
            guard let archive = doc.object(sid) else { continue }
            var sheet = Sheet(name: archive.string("name") ?? "Sheet \(sheets.count + 1)")
            sheet.tables = []
            for tid in tableModels(inSheet: sid) {
                if let t = table(tid, sheetName: sheet.name) { sheet.tables.append(t) }
            }
            if sheet.tables.isEmpty { sheet.tables = [Table()] }
            // header rows / columns of the first table behave like frozen panes
            if let tid = tableModels(inSheet: sid).first, let model = doc.object(tid) {
                let rows = model.bool("header_rows_frozen") == true ? (model.int("number_of_header_rows") ?? 0) : 0
                let cols = model.bool("header_columns_frozen") == true ? (model.int("number_of_header_columns") ?? 0) : 0
                if rows > 0 || cols > 0 { sheet.freezePanes = CellRef(row: rows, col: cols) }
            }
            sheets.append(sheet)
        }
        guard !sheets.isEmpty else { throw SheetError.invalidWorkbook("the Numbers document has no sheets") }
        wb.sheets = Sheets(sheets)
        if let version = wb.sourceInfo?.version, !NumbersReader.isKnownVersion(version) {
            warnings.append(ConversionWarning(.degraded, message: "Numbers document version \(version) is newer than the verified range; read as far as possible"))
        }
        return wb
    }

    static let verifiedMajorVersions = 11...15
    static func isKnownVersion(_ build: String) -> Bool {
        // "M14.0-7040-1" → 14
        guard let m = build.split(separator: "-").first, let major = Int(m.dropFirst().split(separator: ".").first ?? "") else { return true }
        return verifiedMajorVersions.contains(major)
    }

    func sourceInfo() -> SourceInfo {
        var info = SourceInfo(format: .numbers, application: "Numbers")
        if let plist = doc.blob("Metadata/BuildVersionHistory.plist"),
           let list = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String], let last = list.last {
            info.version = last
        }
        return info
    }

    /// TableModelArchive ids of the tables drawn on a sheet, in canvas order.
    func tableModels(inSheet sid: Int) -> [Int] {
        guard let sheet = doc.object(sid) else { return [] }
        return sheet.references("drawable_infos").compactMap { did in
            guard doc.typeName(did) == "TST.TableInfoArchive", let info = doc.object(did) else { return nil }
            return info.reference("tableModel")
        }
    }

    // MARK: - One table

    mutating func table(_ tid: Int, sheetName: String) -> Table? {
        guard let model = doc.object(tid), let store = model.message("base_data_store") else { return nil }
        var t = Table(name: model.string("table_name"))
        let rows = model.int("number_of_rows") ?? 0, cols = model.int("number_of_columns") ?? 0
        if let info = doc.identifiers(ofType: "TST.TableInfoArchive").first(where: { doc.object($0)?.reference("tableModel") == tid }),
           let geometry = doc.object(info)?.message("super")?.message("geometry"), let pos = geometry.message("position") {
            let x = Double(pos.float("x") ?? 0), y = Double(pos.float("y") ?? 0)
            t.anchor = CellRef(row: Swift.max(0, Int(y / NumbersReader.defaultRowHeight)), col: Swift.max(0, Int(x / NumbersReader.defaultColumnWidth)))
        }
        // row heights / column widths / hidden state
        let defaultRowHeight = model.double("default_row_height") ?? NumbersReader.defaultRowHeight
        let defaultColumnWidth = model.double("default_column_width") ?? NumbersReader.defaultColumnWidth
        for bucket in store.message("rowHeaders")?.references("buckets") ?? [] {
            for h in doc.object(bucket)?.messages("headers") ?? [] {
                guard let i = h.int("index") else { continue }
                var d = RowDimension()
                if let s = h.float("size"), s != 0, Double(s) != defaultRowHeight { d.height = Double(s) }
                if (h.int("hidingState") ?? 0) != 0 { d.hidden = true }
                if !d.isDefault { t.rowDimensions[i] = d }
            }
        }
        if let cb = store.reference("columnHeaders") {
            for h in doc.object(cb)?.messages("headers") ?? [] {
                guard let i = h.int("index") else { continue }
                var d = ColumnDimension()
                if let s = h.float("size"), s != 0, Double(s) != defaultColumnWidth { d.width = (Double(s) / NumbersReader.pointsPerCharacter * 100).rounded() / 100 }
                if (h.int("hidingState") ?? 0) != 0 { d.hidden = true }
                if !d.isDefault { t.columnDimensions[i] = d }
            }
        }
        // lookup tables
        let strings = dataList(store.reference("stringTable")) { $0.string("string") }
        let formulas = dataList(store.reference("formula_table")) { $0.message("formula") }
        // rich text: the text, and the links its smart fields carry (Numbers puts a hyperlink on a run of
        // characters; the model has one link per cell, so the first one wins and the rest are reported)
        let richTexts = dataList(store.reference("rich_text_table")) { entry -> (text: String, links: [String])? in
            guard let payload = entry.reference("rich_text_payload"), let storageID = doc.object(payload)?.reference("storage"),
                  let storage = doc.object(storageID) else { return nil }
            let links = storage.message("table_smartfield")?.messages("entries").compactMap { field -> String? in
                guard let id = field.reference("object"), doc.typeName(id) == "TSWP.HyperlinkFieldArchive" else { return nil }
                return doc.object(id)?.string("url_ref")
            } ?? []
            return (storage.strings("text").joined(), links)
        }
        // cells
        let tiles = store.message("tiles")
        let tileSize = tiles?.int("tile_size").flatMap { $0 > 0 ? $0 : nil } ?? 256
        var decoder = NumbersFormulaDecoder { [tableUUIDToName] hex in tableUUIDToName[hex] }
        // cell formatting: the style / format lists of this table, plus the defaults its header and footer regions use
        // `dataOnly` is about formulas, not formatting (the XLSX and ODS readers keep styles either way)
        var styles = NumbersStyleResolver(doc: doc, model: model, store: store)
        var sharedStyles: [CellStyle: SharedStyle] = [:]
        for tileRef in tiles?.messages("tiles") ?? [] {
            guard let tid2 = tileRef.reference("tile"), let tile = doc.object(tid2) else { continue }
            let base = (tileRef.int("tileid") ?? 0) * tileSize
            if tile.bool("last_saved_in_BNC") != true {
                warnings.append(ConversionWarning(.dropped, sheet: sheetName, message: "table \(t.name ?? "") uses pre-BNC cell storage, which is not supported; its cells were skipped"))
                continue
            }
            for rowInfo in tile.messages("rowInfos") {
                let row = base + (rowInfo.int("tile_row_index") ?? 0)
                guard let storage = rowInfo.bytes("cell_storage_buffer"), let offsetsData = rowInfo.bytes("cell_offsets") else { continue }
                let wide = rowInfo.bool("has_wide_offsets") ?? false
                let offsets = NumbersReader.offsets(offsetsData, wide: wide)
                for col in 0..<Swift.min(cols, offsets.count) {
                    let start = offsets[col]
                    guard start >= 0, start < storage.count else { continue }
                    var end = storage.count
                    for k in (col + 1)..<offsets.count where offsets[k] >= 0 { end = offsets[k]; break }
                    guard end > start, end <= storage.count else { continue }
                    let record = storage.subdata(in: (storage.startIndex + start)..<(storage.startIndex + end))
                    do {
                        let s = try CellStorage.decode(record)
                        let value = cellValue(s, row: row, col: col, strings: strings, formulas: formulas, richTexts: richTexts, decoder: &decoder, sheetName: sheetName)
                        let style = styles.style(s, row: row, col: col)
                        let rich = s.richID.flatMap { richTexts[$0] }
                        if value != nil || style != .default {
                            var cell = Cell(value: value)
                            if let first = rich?.links.first {
                                cell.hyperlink = Hyperlink(target: first)
                                if rich!.links.count > 1 {
                                    warnings.append(ConversionWarning(.degraded, subject: .other, sheet: sheetName, location: CellRef(row: row, col: col),
                                                                      message: "the cell holds \(rich!.links.count) links; a cell carries one, so the first was kept"))
                                }
                            }
                            if style != .default {
                                if let shared = sharedStyles[style] { cell.sharedStyle = shared }
                                else { let shared = SharedStyle(style); sharedStyles[style] = shared; cell.sharedStyle = shared }
                            }
                            t.store(cell, at: CellRef(row: row, col: col))
                        }
                    } catch {
                        warnings.append(ConversionWarning(.dropped, sheet: sheetName, location: CellRef(row: row, col: col), message: "\(error)"))
                    }
                }
            }
        }
        for p in decoder.problems.prefix(20) { warnings.append(ConversionWarning(.degraded, sheet: sheetName, message: "formula: \(p)")) }
        t.merges = merges(model, store: store)
        t.nextAppendRow = rows
        _ = cols
        return t
    }

    static func offsets(_ data: Data, wide: Bool) -> [Int] {
        let b = [UInt8](data)
        var out: [Int] = []
        var i = 0
        while i + 1 < b.count {
            let v = Int(Int16(bitPattern: UInt16(b[i]) | UInt16(b[i + 1]) << 8))
            out.append(v < 0 ? -1 : (wide ? v * 4 : v))
            i += 2
        }
        return out
    }

    func dataList<T>(_ id: Int?, _ value: (ProtoMessage) -> T?) -> [Int: T] {
        guard let id, let list = doc.object(id) else { return [:] }
        var out: [Int: T] = [:]
        for e in list.messages("entries") { if let k = e.int("key"), let v = value(e) { out[k] = v } }
        return out
    }

    private mutating func cellValue(_ s: CellStorage, row: Int, col: Int, strings: [Int: String], formulas: [Int: ProtoMessage],
                                    richTexts: [Int: (text: String, links: [String])],
                                    decoder: inout NumbersFormulaDecoder, sheetName: String) -> CellValue? {
        var value: CellValue?
        switch s.cellType {
        case .generic, .span: value = nil
        case .number, .currency:
            if let d = s.decimal {
                if let i = Int("\(d)") { value = .integer(i) } else { value = .number(d) }
            } else if let d = s.double { value = CellValue(d) }
        case .text: value = s.stringID.flatMap { strings[$0] }.map { .text($0) }
        case .date:
            if let seconds = s.seconds {
                let days = Int((seconds / 86400).rounded(.down))
                let rest = seconds - Double(days) * 86400
                value = .date(CivilDateTime(date: CivilDate(dayNumber: NumbersReader.epochDay + days), time: TimeOfDay(dayFraction: rest / 86400)))
            }
        case .bool: value = .bool((s.double ?? 0) > 0)
        case .duration: value = s.double.map { .duration(.milliseconds(Int64(($0 * 1000).rounded()))) }
        case .formulaError: value = .error("#VALUE!")
        case .automatic: value = (s.richID.flatMap { richTexts[$0]?.text } ?? s.stringID.flatMap { strings[$0] }).map { .text($0) }
        case .formula: value = nil
        }
        if let fid = s.formulaID, !options.dataOnly, let archive = formulas[fid] {
            if let text = decoder.text(for: archive, row: row, col: col) {
                return .formula(FormulaExpr.parse(text, dialect: .xlsx), cached: value)
            }
            warnings.append(ConversionWarning(.degraded, sheet: sheetName, location: CellRef(row: row, col: col), message: "formula could not be decoded; cached value kept"))
        }
        return value
    }

    /// Merge ranges: the table's own formula store (`COLON_TRACT` entries) first, then the region map.
    func merges(_ model: ProtoMessage, store: ProtoMessage) -> [CellRange] {
        var out: [CellRange] = []
        if let pairs = model.message("merge_owner")?.message("formula_store")?.messages("formulas") {
            let colonTract = NumbersSchema.shared.enumValue("TSCE.ASTNodeArrayArchive.ASTNodeType", "COLON_TRACT_NODE")
            for pair in pairs {
                guard let node = pair.message("formula")?.message("AST_node_array")?.messages("AST_node").first, node.int("AST_node_type") == colonTract,
                      let tract = node.message("AST_colon_tract"), let r = tract.messages("absolute_row").first, let c = tract.messages("absolute_column").first,
                      let r0 = r.int("range_begin"), let c0 = c.int("range_begin") else { continue }
                let r1 = r.int("range_end") ?? r0, c1 = c.int("range_end") ?? c0
                if r1 > r0 || c1 > c0 { out.append(CellRange(minRow: r0, minCol: c0, maxRow: r1, maxCol: c1)) }
            }
        }
        if out.isEmpty, let mapID = store.reference("merge_region_map"), let map = doc.object(mapID) {
            for range in map.messages("cell_range") {
                guard let origin = range.message("origin")?.int("packedData"), let size = range.message("size")?.int("packedData") else { continue }
                let c0 = origin >> 16, r0 = origin & 0xFFFF, nc = size >> 16, nr = size & 0xFFFF
                if nr > 1 || nc > 1 { out.append(CellRange(minRow: r0, minCol: c0, maxRow: r0 + nr - 1, maxCol: c0 + nc - 1)) }
            }
        }
        return out
    }
}
