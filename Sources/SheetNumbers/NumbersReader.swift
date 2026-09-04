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

    let doc: any NumbersObjectStore
    let options: ReadOptions
    var warnings: [ConversionWarning] = []
    private var tableUUIDToName: [String: String] = [:]

    init(doc: any NumbersObjectStore, options: ReadOptions) { self.doc = doc; self.options = options }

    mutating func workbook() throws -> Workbook {
        guard let document = doc.object(NumbersDocument.documentID), document.typeName == "TN.DocumentArchive" else {
            throw SheetError.malformedPart(path: "Index/Document.iwa", detail: "object 1 is not a TN.DocumentArchive")
        }
        var wb = Workbook(sheets: [])
        wb.dataOnly = options.dataOnly
        wb.sourceInfo = sourceInfo()
        wb.preserved.sourceFormat = .numbers
        if let engine = doc.identifiers(ofType: "TSCE.CalculationEngineArchive").first, doc.object(engine)?.bool("base_date_1904") == true { wb.epoch = .mac1904 }

        let allSheetIDs = document.references("sheets")
        let sheetIDs = allSheetIDs.filter { doc.typeName($0) == "TN.SheetArchive" }
        // name every table first so cross-table references can be rendered
        for sid in sheetIDs {
            let sheetName = doc.object(sid)?.string("name") ?? "Sheet"
            for tid in tableModels(inSheet: sid) {
                guard let model = doc.object(tid) else { continue }
                let name = sheetName + "::" + (model.string("table_name") ?? "Table")
                if let hex = NumbersUUID.hex(model.message("haunted_owner")?.message("owner_uid")) { tableUUIDToName[hex] = name }
                // …and by the identifier a cross-table reference actually names it by
                if let id = model.string("table_id"), let hex = NumbersUUID.hex(NumbersUUID.cfuuid(fromString: id)) { tableUUIDToName[hex] = name }
            }
        }
        // FormulaOwnerDependencies map formula-owner UUIDs to base-owner UUIDs; cross references use the base owner
        for fid in doc.identifiers(ofType: "TSCE.FormulaOwnerDependenciesArchive") {
            guard let f = doc.object(fid), let owner = NumbersUUID.hex(f.message("formula_owner_uid")), let base = NumbersUUID.hex(f.message("base_owner_uid")),
                  let name = tableUUIDToName[owner] else { continue }
            tableUUIDToName[base] = name
        }

        // A tab in Numbers is not always a sheet of cells. A **form** — built on iPhone or iPad — is a
        // data-entry view of a table that already exists on another tab, so it holds no values of its own; it is
        // omitted rather than turned into an empty sheet, which would be a lie the writer would then copy. What is
        // not omitted is the telling: until this was added, the filter above dropped the tab without a word
        // (spec Appendix B.36).
        for sid in allSheetIDs where !sheetIDs.contains(sid) {
            guard let archive = doc.object(sid) else { continue }
            let kind = doc.typeName(sid) ?? "an unknown kind of sheet"
            let name = archive.message("super")?.string("name") ?? archive.string("name") ?? "?"
            if kind == "TN.FormBasedSheetArchive" {
                let feeds = NumbersUUID.hex(archive.message("table_id")).flatMap { tableUUIDToName[$0] }
                warnings.append(ConversionWarning(.dropped, subject: .sheets,
                                                  message: "the form \"\(name)\" is dropped: a Numbers form is a way of typing into "
                                                  + (feeds.map { "the table \($0)" } ?? "a table")
                                                  + ", not a sheet of its own, and the model has no word for it — "
                                                  + "the table it fills in is read as usual"))
            } else {
                warnings.append(ConversionWarning(.dropped, subject: .sheets,
                                                  message: "the tab \"\(name)\" is dropped: it is a \(kind), which the model has no word for"))
            }
        }

        var sheets: [Sheet] = []
        for sid in sheetIDs {
            guard let archive = doc.object(sid) else { continue }
            var sheet = Sheet(name: archive.string("name") ?? "Sheet \(sheets.count + 1)")
            sheet.tables = []
            // a sheet the caller did not ask for: named, left empty, and marked as unread (spec Appendix B.39.10)
            if let selection = options.sheets, !selection.includes(name: sheet.name, index: sheets.count) {
                sheet.preserved.isUnread = true
                warnings.append(ConversionWarning(.degraded, subject: .sheets, sheet: sheet.name,
                                                  message: "the sheet was not read (left out by ReadOptions.sheets); it has no cells here, and writing this workbook back writes it empty"))
                sheets.append(sheet)
                continue
            }
            for tid in tableModels(inSheet: sid) {
                if let t = table(tid, sheetName: sheet.name) { sheet.tables.append(t) }
            }
            if sheet.tables.isEmpty { sheet.tables = [Table()] }
            // conditional formats belong to a Numbers *table*; the model keeps them on the sheet, so the first
            // table's are the sheet's and any further table's are reported rather than silently merged into them
            let ids = tableModels(inSheet: sid)
            if let first = ids.first { for block in conditionalFormats[first] ?? [] { sheet.conditionalFormatting.append(block) } }
            for extra in ids.dropFirst() where !(conditionalFormats[extra] ?? []).isEmpty {
                warnings.append(ConversionWarning(.dropped, subject: .formatting, sheet: sheet.name,
                                                  message: "conditional formats on a second table are dropped: the model keeps them per sheet"))
            }
            // pop-up menus, read back as list validations, live per table the same way
            if let first = ids.first { sheet.dataValidations = validationsByTable[first] ?? [] }
            for extra in ids.dropFirst() where !(validationsByTable[extra] ?? []).isEmpty {
                warnings.append(ConversionWarning(.dropped, subject: .formatting, sheet: sheet.name,
                                                  message: "pop-up menus on a second table are dropped: the model keeps data validations per sheet"))
            }
            // header rows / columns of the first table behave like frozen panes
            if let tid = tableModels(inSheet: sid).first, let model = doc.object(tid) {
                let rows = model.bool("header_rows_frozen") == true ? (model.int("number_of_header_rows") ?? 0) : 0
                let cols = model.bool("header_columns_frozen") == true ? (model.int("number_of_header_columns") ?? 0) : 0
                if rows > 0 || cols > 0 { sheet.freezePanes = CellRef(row: rows, col: cols) }
            }
            // A Numbers sheet is a canvas. Whatever else is standing on it cannot come into the model, and until
            // this was added it went without a word — the one thing the library promises never to do.
            for (kind, count) in nonTableDrawables(inSheet: sid) {
                warnings.append(ConversionWarning(.dropped, subject: .objects, sheet: sheet.name,
                                                  message: count == 1 ? "the sheet holds \(kind), which the model has no place for"
                                                                      : "the sheet holds \(count) × \(kind), which the model has no place for"))
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

    /// What a Numbers sheet may hold besides a table. A Numbers sheet is a canvas, not a grid: tables, charts,
    /// images, shapes and text boxes all sit on it side by side. The model has a word for the table only, so the
    /// rest is reported — `.objects`, the subject that names charts and drawings everywhere else in the library.
    /// Anything not named here is reported by its archive name rather than guessed at.
    static let drawableNames: [String: String] = [
        "TSCH.ChartDrawableArchive": "a chart",
        "TSD.ImageArchive": "an image",
        "TSD.ShapeArchive": "a shape",              // a text box is a shape carrying text
        "TSD.MovieArchive": "a movie",
        "TSD.GroupArchive": "a group of objects",
        "TSD.ConnectionLineArchive": "a connection line",
        "TSD.DrawableArchive": "a drawing"
    ]

    /// Everything on a sheet's canvas that is not a table, counted by kind.
    func nonTableDrawables(inSheet sid: Int) -> [(kind: String, count: Int)] {
        guard let sheet = doc.object(sid) else { return [] }
        var counts: [String: Int] = [:]
        for did in sheet.references("drawable_infos") where doc.typeName(did) != "TST.TableInfoArchive" {
            counts[doc.typeName(did) ?? "an object of an unknown kind", default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { (NumbersReader.drawableNames[$0.key] ?? $0.key, $0.value) }
    }

    /// TableModelArchive ids of the tables drawn on a sheet, in canvas order.
    func tableModels(inSheet sid: Int) -> [Int] { NumbersCells.tableModels(inSheet: sid, doc: doc) }

    // MARK: - One table

    /// table model id → what its conditional-style list said, read back into the model's own vocabulary.
    private var conditionalFormats: [Int: [ConditionalFormatting]] = [:]

    /// table model id → the table's pop-up menus, read back as `.list` validations.
    private var validationsByTable: [Int: [DataValidation]] = [:]

    /// A control spec as the model's own word, for the four kinds that have one. Nil for the rest — a pop-up
    /// menu (which becomes a validation instead) and the kinds nobody models (a stock quote). The dial's bounds
    /// are read as data, not normalised: Numbers itself writes a stepper whose maximum is the cell's own value.
    static func control(fromSpec spec: ProtoMessage) -> CellControl? {
        let kind = NumbersWriter.controlInteractionTypes.first { $0.value == spec.int("interaction_type") }?.key
        guard let kind else { return nil }
        return CellControl(kind: kind, minimum: spec.double("range_control_min") ?? 0,
                           maximum: spec.double("range_control_max") ?? 0,
                           increment: spec.double("range_control_inc") ?? 0)
    }

    /// The pop-up menus among a table's cell controls, as list validations over the cells that wear them.
    /// Cells whose control is anything else the model has no word for (a stock quote, or a menu an inline list
    /// cannot spell) come back in `unreadable`, for the caller to report.
    private func validations(controls: [Int: [CellRef]], store: ProtoMessage) -> (rules: [DataValidation], unreadable: [CellRef]) {
        guard !controls.isEmpty else { return ([], []) }
        let popup = NumbersWriter.popupInteractionType
        let specs = dataList(store.reference("control_cell_spec_table")) { $0.message("cell_spec") }
        var rules: [DataValidation] = []
        var unreadable: [CellRef] = []
        for (key, refs) in controls.sorted(by: { $0.key < $1.key }) {
            guard let spec = specs[key], spec.int("interaction_type") == popup,
                  let menu = spec.reference("chooser_control_popup_model"), let items = popupItems(menu) else {
                unreadable.append(contentsOf: refs)
                continue
            }
            // The shape Numbers itself gives a pop-up when it exports to Excel: a strict inline list that
            // allows blank (every menu carries the blank choice) and shows its messages.
            rules.append(DataValidation(kind: .list, ranges: NumbersReader.condense(refs),
                                        formula1: "\"\(items.joined(separator: ","))\"",
                                        allowBlank: true, showInputMessage: true, showErrorMessage: true))
        }
        return (rules, unreadable.sorted { ($0.row, $0.col) < ($1.row, $1.col) })
    }

    /// The choices of a pop-up menu, spelt the way Numbers itself exports them: text as it is, a whole number
    /// without its decimal point. A menu holding what an inline list cannot spell — a date, a boolean, text with
    /// a comma or quote in it, or no choices at all — returns nil, and the control is reported instead.
    private func popupItems(_ id: Int) -> [String]? {
        guard let menu = doc.object(id), menu.typeName == "TST.PopUpMenuModel" else { return nil }
        let kinds = { NumbersSchema.shared.enumValue("TSCE.CellValueArchive.CellValueType", $0) }
        var out: [String] = []
        for item in menu.messages("tsce_item") {
            switch item.int("cell_value_type") {
            case kinds("NIL_TYPE"): continue    // the blank choice every menu carries
            case kinds("STRING_TYPE"):
                guard let s = item.message("string_value")?.string("value"), !s.contains(","), !s.contains("\"") else { return nil }
                out.append(s)
            case kinds("NUMBER_TYPE"):
                guard let v = item.message("number_value")?.double("value") else { return nil }
                out.append(v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : "\(v)")
            default: return nil
            }
        }
        return out.isEmpty ? nil : out
    }

    /// The cells that named each entry of the table's conditional-style list, as rules over ranges. Numbers keeps
    /// one *set* of rules per cell; the model keeps rules over ranges, so cells naming the same set become one block.
    private mutating func conditionalFormatting(sets: [Int: Int], cells: [Int: [CellRef]],
                                                styles: NumbersStyleResolver, sheetName: String) -> [ConditionalFormatting] {
        var out: [ConditionalFormatting] = []
        var problems: [String] = []
        var priority = 1
        for (key, refs) in cells.sorted(by: { $0.key < $1.key }) {
            guard let setID = sets[key], let archive = doc.object(setID) else { continue }
            let rules = archive.message("rules")?.messages("rule") ?? []
            var read: [ConditionalFormattingRule] = []
            for rule in rules {
                guard let r = NumbersConditional.rule(rule, priority: priority,
                                                      style: { styles.differentialStyle(cell: $0, text: $1) },
                                                      problems: &problems) else { continue }
                read.append(r)
                priority += 1
            }
            guard !read.isEmpty else { continue }
            out.append(ConditionalFormatting(ranges: NumbersReader.condense(refs), rules: read))
        }
        for p in Set(problems).sorted().prefix(10) {
            warnings.append(ConversionWarning(.dropped, subject: .formatting, sheet: sheetName, message: "conditional format: \(p)"))
        }
        return out
    }

    /// Cells → as few rectangles as a column-by-column sweep can make of them. Numbers records the rule on every
    /// cell, so a rule over one column comes back as eight cells; the model would rather say `A1:A8`.
    static func condense(_ refs: [CellRef]) -> MultiCellRange {
        var byColumn: [Int: [Int]] = [:]
        for r in refs { byColumn[r.col, default: []].append(r.row) }
        var ranges: [CellRange] = []
        for (col, rows) in byColumn {
            var run: [Int] = []
            func flush() {
                guard let first = run.first, let last = run.last else { return }
                ranges.append(CellRange(minRow: first, minCol: col, maxRow: last, maxCol: col))
                run = []
            }
            for row in rows.sorted() {
                if let last = run.last, row != last + 1 { flush() }
                run.append(row)
            }
            flush()
        }
        // a rectangle spanning several columns is worth saying once
        var merged: [CellRange] = []
        for range in ranges.sorted(by: { ($0.minCol, $0.minRow) < ($1.minCol, $1.minRow) }) {
            if var last = merged.last, last.minRow == range.minRow, last.maxRow == range.maxRow, last.maxCol + 1 == range.minCol {
                last = CellRange(minRow: last.minRow, minCol: last.minCol, maxRow: range.maxRow, maxCol: range.maxCol)
                merged[merged.count - 1] = last
            } else {
                merged.append(range)
            }
        }
        return MultiCellRange(merged)
    }

    /// Whether a character style is the document's own hyperlink style, along its parent chain.
    static func isHyperlinkStyle(_ id: Int, doc: any NumbersObjectStore) -> Bool {
        var cursor: Int? = id
        var seen = Set<Int>()
        while let current = cursor, seen.insert(current).inserted, let object = doc.object(current) {
            if object.message("super")?.string("style_identifier") == "character-style-hyperlink" { return true }
            cursor = object.message("super")?.reference("parent")
        }
        return false
    }

    mutating func table(_ tid: Int, sheetName: String) -> Table? {
        guard let model = doc.object(tid), let store = model.message("base_data_store") else { return nil }
        var t = Table(name: model.string("table_name"))
        /// Cells carrying an interactive control, by the control-list key they name. A checkbox, stepper, slider
        /// or star rating goes onto the cell as `Cell.control`; a pop-up menu comes back as a `.list` validation;
        /// what is left (a stock quote, a menu an inline list cannot spell) is reported rather than passed over
        /// in silence, so only those keys are collected here.
        var controlledCells: [Int: [CellRef]] = [:]
        let controlSpecs = dataList(store.reference("control_cell_spec_table")) { $0.message("cell_spec") }
        let modelledControls = controlSpecs.compactMapValues { NumbersReader.control(fromSpec: $0) }
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
        // conditional formats: the table's own list, and (below) the cells that name each of its entries
        let conditionalSets = dataList(store.reference("conditionalstyletable")) { $0.reference("reference") }
        var conditionalCells: [Int: [CellRef]] = [:]

        // cell formatting: the style / format lists of this table, plus the defaults its header and footer regions
        // use. `dataOnly` is about formulas, not formatting (the XLSX and ODS readers keep styles either way).
        var styles = NumbersStyleResolver(doc: doc, model: model, store: store)

        // lookup tables
        let strings = dataList(store.reference("stringTable")) { $0.string("string") }
        let formulas = dataList(store.reference("formula_table")) { $0.message("formula") }
        // rich text: the text, the links its smart fields carry, and the formatting runs
        let richTexts = NumbersCells.richTexts(store: store, doc: doc, styles: styles)
        // the notes on cells: the table's comment list, and the author each belongs to
        let comments = dataList(store.reference("commentStorageTable")) { entry -> CellNote? in
            guard let id = entry.reference("comment_storage"), let archive = doc.object(id), let text = archive.string("text") else { return nil }
            let author = archive.reference("author").flatMap { doc.object($0)?.string("name") }
            return CellNote(text, author: author ?? "")
        }
        // cells
        var decoder = NumbersFormulaDecoder { [tableUUIDToName] hex in tableUUIDToName[hex] }
        /// One shared style per resolver key (a text style, a cell style and a format), so a cell costs a
        /// dictionary lookup on an integer rather than a hash of its whole style.
        var sharedStyles: [Int: SharedStyle] = [:]
        /// Cells covered by an array formula, by the anchor their spill formula names (Appendix B.26).
        var spillCells: [CellRef: [CellRef]] = [:]
        for (base, tileID) in NumbersCells.tiles(of: store).tiles {
            guard let tile = doc.object(tileID) else { continue }
            if tile.bool("last_saved_in_BNC") != true {
                warnings.append(ConversionWarning(.dropped, sheet: sheetName, message: "table \(t.name ?? "") uses pre-BNC cell storage, which is not supported; its cells were skipped"))
                continue
            }
            for rowInfo in tile.messages("rowInfos") {
                let row = base + (rowInfo.int("tile_row_index") ?? 0)
                NumbersCells.forEachRecord(in: rowInfo, cols: cols) { col, record in
                    let s: CellStorage
                    switch record {
                    case .success(let decoded): s = decoded
                    case .failure(let error):
                        warnings.append(ConversionWarning(.dropped, sheet: sheetName, location: CellRef(row: row, col: col), message: "\(error)"))
                        return
                    }
                    if let cid = s.conditionalStyleID { conditionalCells[cid, default: []].append(CellRef(row: row, col: col)) }
                    var control: CellControl?
                    if let cid = s.controlID {
                        if let modelled = modelledControls[cid] { control = modelled }
                        else { controlledCells[cid, default: []].append(CellRef(row: row, col: col)) }
                    }
                    // a spill cell holds `337(anchor)`, which is not a formula of its own but the anchor's
                    // array formula showing one element here — read the value, remember the anchor
                    var storage = s
                    if let fid = s.formulaID, let archive = formulas[fid],
                       let anchor = NumbersFormulaDecoder.spillAnchor(archive, row: row, col: col) {
                        spillCells[anchor, default: []].append(CellRef(row: row, col: col))
                        storage.formulaID = nil
                    }
                    let (value, undecoded) = NumbersCells.value(storage, row: row, col: col, strings: strings, formulas: formulas,
                                                                richTexts: richTexts, decoder: &decoder, dataOnly: options.dataOnly)
                    if undecoded {
                        warnings.append(ConversionWarning(.degraded, sheet: sheetName, location: CellRef(row: row, col: col), message: "formula could not be decoded; cached value kept"))
                    }
                    let (style, styleKey) = styles.resolve(s, row: row, col: col)
                    let rich = s.richID.flatMap { richTexts[$0] }
                    let note = s.commentID.flatMap { comments[$0] }
                    if value != nil || style != .default || note != nil || control != nil {
                        var cell = Cell(value: value)
                        cell.comment = note
                        cell.control = control
                        if let first = rich?.links.first {
                            cell.hyperlink = Hyperlink(target: first)
                            if rich!.links.count > 1 {
                                warnings.append(ConversionWarning(.degraded, subject: .other, sheet: sheetName, location: CellRef(row: row, col: col),
                                                                  message: "the cell holds \(rich!.links.count) links; a cell carries one, so the first was kept"))
                            }
                        }
                        if style != .default {
                            if let shared = sharedStyles[styleKey] { cell.sharedStyle = shared }
                            else { let shared = SharedStyle(style); sharedStyles[styleKey] = shared; cell.sharedStyle = shared }
                        }
                        t.store(cell, at: CellRef(row: row, col: col))
                    }
                }
            }
        }
        for p in decoder.problems.prefix(20) { warnings.append(ConversionWarning(.degraded, sheet: sheetName, message: "formula: \(p)")) }
        let (rules, unreadableControls) = validations(controls: controlledCells, store: store)
        validationsByTable[tid] = rules
        if let first = unreadableControls.first {
            let n = unreadableControls.count
            let subject = n == 1 ? "the cell at \(first.a1) carries" : "\(n) cells starting at \(first.a1) carry"
            warnings.append(ConversionWarning(.dropped, subject: .other, sheet: sheetName, location: first,
                                              message: "\(subject) a Numbers control the model has no word for (a stock quote, or a menu an inline list cannot spell); the value is kept, the control is not"))
        }
        // the cells spilling one anchor, plus the anchor itself, are that array formula's range — the model's
        // own shape for one (the anchor keeps the formula, `arrayFormulas` the range, covered cells the values)
        for (anchor, covered) in spillCells where anchor.row < rows && anchor.col < cols {
            let points = covered + [anchor]
            t.arrayFormulas[anchor] = CellRange(minRow: points.map(\.row).min()!, minCol: points.map(\.col).min()!,
                                                maxRow: points.map(\.row).max()!, maxCol: points.map(\.col).max()!)
        }
        conditionalFormats[tid] = conditionalFormatting(sets: conditionalSets, cells: conditionalCells, styles: styles, sheetName: sheetName)
        t.merges = merges(model, store: store)
        t.nextAppendRow = rows
        readFilter(model, into: &t, sheetName: sheetName)
        readCategories(model, table: t, sheetName: sheetName)
        readSortOrder(model, table: t, sheetName: sheetName)
        _ = cols
        return t
    }

    /// The lane a UID names, from a table's base UID map: `index_for_uid[sortedPos]` is the real index of the
    /// UID at `sortedPos` of the sorted list — the same arrangement the writer builds (Appendix B.19).
    private func laneIndexes(of model: ProtoMessage, rows: Bool) -> [String: Int] {
        guard let mapID = model.reference("base_column_row_uids"), let map = doc.object(mapID) else { return [:] }
        let uids = map.messages(rows ? "sorted_row_uids" : "sorted_column_uids")
        let real = map.ints(rows ? "row_index_for_uid" : "column_index_for_uid")
        var out: [String: Int] = [:]
        for (pos, uid) in uids.enumerated() where real.indices.contains(pos) {
            if let hex = NumbersUUID.hex(uid) { out[hex] = real[pos] }
        }
        return out
    }

    /// A Numbers filter: rules the model has no word for, hiding rows it can say. The rows the filter hides come
    /// back as hidden rows and the rules are dropped out loud — the same trade Numbers itself makes when it
    /// exports to Excel (measured: no autoFilter element, the filtered-out rows written `hidden="1"`).
    private mutating func readFilter(_ model: ProtoMessage, into t: inout Table, sheetName: String) {
        guard let owner = model.message("hidden_states_owner") else { return }
        var hiddenRows = 0
        var ruleCount = 0
        var offRuleCount = 0
        for state in owner.messages("hidden_states") {
            for (extentName, isRow) in [("row_hidden_state_extent", true), ("column_hidden_state_extent", false)] {
                guard let extent = state.message(extentName) else { continue }
                let set = extent.reference("filter_set").flatMap { doc.object($0) }
                guard set?.bool("is_enabled") != false else {
                    // A switched-off filter hides nothing — Numbers empties the hidden-state list when the
                    // switch goes off (measured on a document whose filter was set up and then turned off) —
                    // but it keeps the rules, switched off, for the person to turn back on. The model has no
                    // place for them, so they are dropped and counted below.
                    offRuleCount += set?.messages("filter_rules").count ?? 0
                    continue
                }
                let lanes = laneIndexes(of: model, rows: isRow)
                for hidden in extent.messages("base_hidden_states") where hidden.bool("filtered") == true {
                    guard let hex = NumbersUUID.hex(hidden.message("row_or_column_uid")), let index = lanes[hex] else { continue }
                    if isRow {
                        var d = t.rowDimensions[index] ?? RowDimension()
                        d.hidden = true
                        t.rowDimensions[index] = d
                        hiddenRows += 1
                    } else {
                        var d = t.columnDimensions[index] ?? ColumnDimension()
                        d.hidden = true
                        t.columnDimensions[index] = d
                    }
                }
                ruleCount += set?.messages("filter_rules").count ?? 0
            }
        }
        if ruleCount > 0 {
            warnings.append(ConversionWarning(.degraded, subject: .other, sheet: sheetName,
                                              message: "table \(t.name ?? ""): a Numbers filter (\(ruleCount) rule(s)) is dropped — the rows it hides are kept as hidden rows, the same trade Numbers itself makes when it exports to Excel"))
        }
        if offRuleCount > 0 {
            warnings.append(ConversionWarning(.dropped, subject: .other, sheet: sheetName,
                                              message: "table \(t.name ?? ""): a switched-off Numbers filter (\(offRuleCount) rule(s)) is dropped — it was hiding nothing, and its rules have no place in the model; Numbers' own Excel export drops them too"))
        }
        _ = hiddenRows
    }

    /// A Numbers sort order (Organise ▸ Sort): rules the table remembers so the person can sort again. Applying
    /// a sort reorders the stored rows themselves, so the data already comes back in the sorted order — every
    /// reader gets that for free. The rules have no place in the model and are dropped out loud; Numbers' own
    /// Excel export drops them too and hands over the sorted rows alone (measured: no sortState element).
    private mutating func readSortOrder(_ model: ProtoMessage, table t: Table, sheetName: String) {
        let rules = model.message("sort_order")?.messages("rules") ?? []
        guard !rules.isEmpty else { return }
        let names = rules.map { rule -> String in
            guard let index = rule.int("index") else { return "a column" }
            let heading = t[CellRef(row: 0, col: index)]?.stringValue
            return heading?.isEmpty == false ? heading! : "column \(index + 1)"
        }
        warnings.append(ConversionWarning(.degraded, subject: .other, sheet: sheetName,
                                          message: "table \(t.name ?? ""): a Numbers sort order (\(rules.count) rule(s), by \(names.joined(separator: ", "))) is dropped — the rows already come back in that order, and Numbers' own Excel export drops the rules the same way"))
    }

    /// A category grouping on an ordinary table (Organise ▸ Categories): the same group-by machinery a pivot
    /// uses, hung on the table's own category owner with the grouped columns named. The model has no word for
    /// it, so the rows are kept flat in stored order and the grouping is dropped out loud — Numbers' own Excel
    /// export bakes the grouped *look* into extra label rows and a shifted grid instead, which would change the
    /// data, so it is not copied.
    private mutating func readCategories(_ model: ProtoMessage, table t: Table, sheetName: String) {
        guard let catID = model.reference("category_owner") else { return }
        let lanes = laneIndexes(of: model, rows: false)
        var names: [String] = []
        var offNames: [String] = []
        for gbID in doc.object(catID)?.references("group_by") ?? [] {
            guard let gb = doc.object(gbID) else { continue }
            // Switching categories off flips is_enabled and keeps everything else — the grouped columns and the
            // whole tree (measured on a document whose categories were set up and then turned off). The set-up
            // has no place in the model either way, so both states are named; only the wording differs.
            let enabled = gb.bool("is_enabled") != false
            for column in gb.messages("group_column") {
                guard let hex = NumbersUUID.hex(column.message("column_uid")), let index = lanes[hex] else { continue }
                let heading = t[CellRef(row: 0, col: index)]?.stringValue
                let name = heading?.isEmpty == false ? heading! : "column \(index + 1)"
                if enabled { names.append(name) } else { offNames.append(name) }
            }
        }
        // a pivot summary's own group-by names no columns, so neither warning fires on a pivot
        if !names.isEmpty {
            warnings.append(ConversionWarning(.degraded, subject: .other, sheet: sheetName,
                                              message: "table \(t.name ?? ""): a category grouping by \(names.joined(separator: ", ")) is dropped — the model has no word for Numbers categories; the rows are kept flat in stored order"))
        }
        if !offNames.isEmpty {
            warnings.append(ConversionWarning(.dropped, subject: .other, sheet: sheetName,
                                              message: "table \(t.name ?? ""): a switched-off category grouping by \(offNames.joined(separator: ", ")) is dropped — it was grouping nothing on screen, and its set-up has no place in the model; Numbers' own Excel export drops it too"))
        }
    }

    static func offsets(_ data: Data, wide: Bool) -> [Int] {
        data.withUnsafeBytes { raw -> [Int] in
            let b = raw.bindMemory(to: UInt8.self)
            var out: [Int] = []
            out.reserveCapacity(b.count / 2)
            var i = 0
            while i + 1 < b.count {
                let v = Int(Int16(bitPattern: UInt16(b[i]) | UInt16(b[i + 1]) << 8))
                out.append(v < 0 ? -1 : (wide ? v * 4 : v))
                i += 2
            }
            return out
        }
    }

    func dataList<T>(_ id: Int?, _ value: (ProtoMessage) -> T?) -> [Int: T] { NumbersCells.dataList(id, doc: doc, value) }

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
