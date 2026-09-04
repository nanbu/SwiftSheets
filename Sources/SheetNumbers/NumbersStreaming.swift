import Foundation
import SheetCore

/// Reads a Numbers document one row at a time, without ever building it (spec Appendix B.40.3).
/// `StreamingReader` in the `SwiftSheets` module opens a file of any format and hands it to this reader when it
/// is a Numbers document; the API is the same here.
///
/// The document is indexed, not decoded: every part's archive headers are read once to learn where each object
/// lies, and the parts that hold nothing but tiles — the 256-row blocks a table's cells live in — are let go
/// after that and expanded again only when a walk reaches them (`NumbersObjectIndex`). A walk holds the
/// table's string and formula lists, the tile in hand and the row on its way to the caller.
///
/// A Numbers sheet is a canvas and may carry several tables. `forEachRow(inSheet:)` walks the first, as
/// `Sheet.table` is the first; `table:` reaches the others, in canvas order, and `tableCount(inSheet:)` says how
/// many there are. Row numbers are the table's own.
///
/// **What it does not do.** Only values and (on request) formatting: no merges, no notes, no controls, nothing
/// preserved. A formula that cannot be turned back into text comes as its cached value — the whole-workbook
/// reader reports that with a warning; this reader has no warning channel and says so here instead. A tile in
/// the pre-BNC storage the library does not read is an error rather than a silently shorter walk.
public struct NumbersStreamingReader: StreamingRowSource {
    let index: NumbersObjectIndex
    /// The sheets of the document, in the file's order.
    public let sheetNames: [String]
    private let tablesBySheet: [String: [Int]]
    private let tableNamesBySheet: [String: [String]]
    /// Table UUID → "Sheet::Table", for the sheet-name slot of a cross-table reference in a formula.
    private let tableUUIDToName: [String: String]

    /// Opens a document, saved as a file or as a folder.
    public init(contentsOf url: URL, limits: ZipLimits = ZipLimits()) throws {
        if url.isDirectoryOnDisk {
            guard NumbersBundle.isBundle(url) else { throw SheetError.unrecognizedFormat }
            try self.init(index: try NumbersObjectIndex(folder: url, limits: limits))
        } else {
            try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe), limits: limits)
        }
    }

    /// `limits` is what the container may declare about itself before it is refused (`ReadOptions.limits`). A
    /// password-protected document is refused by name: Numbers' encryption is not documented.
    public init(data: Data, limits: ZipLimits = ZipLimits()) throws {
        try self.init(index: try NumbersObjectIndex(data: data, limits: limits))
    }

    /// A document saved as a folder (a package on disk).
    public init(folder url: URL, limits: ZipLimits = ZipLimits()) throws {
        try self.init(index: try NumbersObjectIndex(folder: url, limits: limits))
    }

    init(index: NumbersObjectIndex) throws {
        self.index = index
        guard let document = index.object(NumbersDocument.documentID), document.typeName == "TN.DocumentArchive" else {
            throw SheetError.malformedPart(path: "Index/Document.iwa", detail: "object 1 is not a TN.DocumentArchive")
        }
        var names: [String] = []
        var tables: [String: [Int]] = [:]
        var tableNames: [String: [String]] = [:]
        var uuidToName: [String: String] = [:]
        // a tab that is not a sheet of cells (a form) has no rows to walk and is left out, as the reader does
        for sid in document.references("sheets") where index.typeName(sid) == "TN.SheetArchive" {
            guard let archive = index.object(sid) else { continue }
            let name = archive.string("name") ?? "Sheet \(names.count + 1)"
            guard tables[name] == nil else { continue }   // a duplicated name: the first tab keeps it
            names.append(name)
            let models = NumbersCells.tableModels(inSheet: sid, doc: index)
            tables[name] = models
            tableNames[name] = models.map { index.object($0)?.string("table_name") ?? "Table" }
            for tid in models {
                guard let model = index.object(tid) else { continue }
                let qualified = name + "::" + (model.string("table_name") ?? "Table")
                if let hex = NumbersUUID.hex(model.message("haunted_owner")?.message("owner_uid")) { uuidToName[hex] = qualified }
                if let id = model.string("table_id"), let hex = NumbersUUID.hex(NumbersUUID.cfuuid(fromString: id)) { uuidToName[hex] = qualified }
            }
        }
        // FormulaOwnerDependencies map formula-owner UUIDs to base-owner UUIDs; cross references use the base owner
        for fid in index.identifiers(ofType: "TSCE.FormulaOwnerDependenciesArchive") {
            guard let f = index.object(fid), let owner = NumbersUUID.hex(f.message("formula_owner_uid")), let base = NumbersUUID.hex(f.message("base_owner_uid")),
                  let qualified = uuidToName[owner] else { continue }
            uuidToName[base] = qualified
        }
        guard !names.isEmpty else { throw SheetError.invalidWorkbook("the Numbers document has no sheets") }
        sheetNames = names
        tablesBySheet = tables
        tableNamesBySheet = tableNames
        tableUUIDToName = uuidToName
    }

    /// How many tables stand on the sheet's canvas — at least one, as the model gives an empty sheet one table.
    public func tableCount(inSheet name: String) throws -> Int {
        guard let models = tablesBySheet[name] else { throw SheetError.invalidWorkbook("no sheet named \(name)") }
        return Swift.max(1, models.count)
    }

    /// The names of the tables on a sheet, in canvas order — what `table:` counts through.
    public func tableNames(inSheet name: String) throws -> [String] {
        guard let names = tableNamesBySheet[name] else { throw SheetError.invalidWorkbook("no sheet named \(name)") }
        return names
    }

    /// Visits every row of one table of a sheet in order. Throwing from `body` stops the walk and rethrows.
    public func forEachRow(inSheet name: String, table: Int = 0, options: StreamingReadOptions = StreamingReadOptions(),
                           _ body: (StreamedRow) throws -> Void) throws {
        let walk = try rowWalk(inSheet: name, table: table, options: options)
        while let row = try walk.next() { try body(row) }
    }

    /// The rows of one table as a sequence to iterate — `for try await row in reader.rows(inSheet: "売上")` —
    /// one tile of the table expanded at a time as the loop asks, so a walk that stops early reads no further.
    public func rows(inSheet name: String, table: Int = 0, options: StreamingReadOptions = StreamingReadOptions()) -> AsyncThrowingStream<StreamedRow, Error> {
        StreamingRowSequence.make { try rowWalk(inSheet: name, table: table, options: options) }
    }

    package func rowWalk(inSheet name: String, table: Int, options: StreamingReadOptions) throws -> any StreamingRowWalk {
        try checkTable(table, inSheet: name)
        let models = tablesBySheet[name] ?? []
        guard models.indices.contains(table) else { return EmptyWalk() }   // a sheet with no table: nothing to walk
        return try TableWalk(index: index, modelID: models[table], options: options, tableUUIDToName: tableUUIDToName)
    }

    /// The same walk, as dense value arrays (openpyxl's `values_only=True`). `width` pads every row to that many
    /// columns so the rows line up.
    public func forEachRow(inSheet name: String, table: Int = 0, valuesOnly width: Int?,
                           options: StreamingReadOptions = StreamingReadOptions(),
                           _ body: ([CellValue?]) throws -> Void) throws {
        try forEachRow(inSheet: name, table: table, options: options) { try body($0.values(width: width)) }
    }

    final class EmptyWalk: StreamingRowWalk { func next() throws -> StreamedRow? { nil } }

    /// One table, tile by tile: the lists a cell's value indexes into are read once; each tile is decoded when
    /// the walk reaches it, its rows delivered in row order, and then let go.
    final class TableWalk: StreamingRowWalk {
        private let index: NumbersObjectIndex
        private let options: StreamingReadOptions
        private let cols: Int
        private let strings: [Int: String]
        private let formulas: [Int: ProtoMessage]
        private let richTexts: [Int: NumbersCells.RichText]
        private var styles: NumbersStyleResolver?
        private var decoder: NumbersFormulaDecoder
        private let tiles: [(base: Int, id: Int)]
        private var tileCursor = 0
        /// The rows of the tile in hand, in row order, and how far along them the walk is.
        private var rows: [(row: Int, info: ProtoMessage)] = []
        private var rowCursor = 0

        init(index: NumbersObjectIndex, modelID: Int, options: StreamingReadOptions, tableUUIDToName: [String: String]) throws {
            guard let model = index.object(modelID), let store = model.message("base_data_store") else {
                throw SheetError.malformedPart(path: "Index/Tables", detail: "table model \(modelID) has no data store")
            }
            self.index = index
            self.options = options
            cols = model.int("number_of_columns") ?? 0
            strings = NumbersCells.dataList(store.reference("stringTable"), doc: index) { $0.string("string") }
            // the formula list is only needed to spell formulas out; the cached values are in the cells themselves
            formulas = options.dataOnly ? [:] : NumbersCells.dataList(store.reference("formula_table"), doc: index) { $0.message("formula") }
            let resolver = NumbersStyleResolver(doc: index, model: model, store: store)
            richTexts = NumbersCells.richTexts(store: store, doc: index, styles: resolver)
            styles = options.includeStyles ? resolver : nil
            decoder = NumbersFormulaDecoder { tableUUIDToName[$0] }
            tiles = NumbersCells.tiles(of: store).tiles.sorted { $0.base < $1.base }
        }

        func next() throws -> StreamedRow? {
            while true {
                if rowCursor == rows.count {
                    guard tileCursor < tiles.count else { return nil }
                    let (base, id) = tiles[tileCursor]
                    tileCursor += 1
                    guard let tile = index.object(id) else { continue }
                    guard tile.bool("last_saved_in_BNC") == true else {
                        throw SheetError.unsupportedFeature("the table uses pre-BNC cell storage, which is not supported")
                    }
                    rows = tile.messages("rowInfos").map { (base + ($0.int("tile_row_index") ?? 0), $0) }.sorted { $0.row < $1.row }
                    rowCursor = 0
                    continue
                }
                let (row, info) = rows[rowCursor]
                rowCursor += 1
                var cells: [StreamedCell] = []
                try NumbersCells.forEachRecord(in: info, cols: cols) { col, record in
                    let s = try record.get()
                    var storage = s
                    // a spill cell holds `337(anchor)`: the anchor's array formula showing one element here (B.26)
                    if let fid = s.formulaID, let archive = formulas[fid], NumbersFormulaDecoder.spillAnchor(archive, row: row, col: col) != nil {
                        storage.formulaID = nil
                    }
                    let (value, _) = NumbersCells.value(storage, row: row, col: col, strings: strings, formulas: formulas,
                                                        richTexts: richTexts, decoder: &decoder, dataOnly: options.dataOnly)
                    var style: CellStyle?
                    if styles != nil { style = styles!.style(s, row: row, col: col) }
                    guard value != nil || (style != nil && style != .default) else { return }
                    cells.append(StreamedCell(ref: CellRef(row: row, col: col), value: value, style: style))
                }
                let streamed = StreamedRow(index: row, cells: cells)
                if options.includesEmptyRows || !streamed.isEmpty { return streamed }
            }
        }
    }
}
