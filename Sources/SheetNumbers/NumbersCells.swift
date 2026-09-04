import Foundation
import SheetCore

/// The reading of a table's cells that the whole-workbook reader and the streaming reader share (spec Appendix
/// B.40.3): the records of a tile row, the value a record holds, the table's lookup lists, and the formatting runs
/// of rich text. Written against `NumbersObjectStore`, so either document store serves.
enum NumbersCells {
    typealias RichText = (text: String, links: [String], runs: [TextRun])

    /// TableModelArchive ids of the tables drawn on a sheet, in canvas order.
    static func tableModels(inSheet sid: Int, doc: any NumbersObjectStore) -> [Int] {
        guard let sheet = doc.object(sid) else { return [] }
        return sheet.references("drawable_infos").compactMap { did in
            guard doc.typeName(did) == "TST.TableInfoArchive", let info = doc.object(did) else { return nil }
            return info.reference("tableModel")
        }
    }

    /// The entries of a `TST.TableDataList` by key.
    static func dataList<T>(_ id: Int?, doc: any NumbersObjectStore, _ value: (ProtoMessage) -> T?) -> [Int: T] {
        guard let id, let list = doc.object(id) else { return [:] }
        var out: [Int: T] = [:]
        for e in list.messages("entries") { if let k = e.int("key"), let v = value(e) { out[k] = v } }
        return out
    }

    /// The cell records of one tile row, by column. `cell_offsets` says where each column's record starts in
    /// `cell_storage_buffer` (−1 for no cell), and the next record's start is where this one ends. A record that
    /// will not decode is handed over as the error, for the caller to report or refuse.
    static func forEachRecord(in rowInfo: ProtoMessage, cols: Int, _ body: (_ col: Int, _ record: Result<CellStorage, Error>) throws -> Void) rethrows {
        guard let storage = rowInfo.bytes("cell_storage_buffer"), let offsetsData = rowInfo.bytes("cell_offsets") else { return }
        let offsets = NumbersReader.offsets(offsetsData, wide: rowInfo.bool("has_wide_offsets") ?? false)
        try storage.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            for col in 0..<Swift.min(cols, offsets.count) {
                let start = offsets[col]
                guard start >= 0, start < b.count else { continue }
                var end = b.count
                for k in (col + 1)..<offsets.count where offsets[k] >= 0 { end = offsets[k]; break }
                guard end > start, end <= b.count else { continue }
                try body(col, Result { try CellStorage.decode(UnsafeBufferPointer(rebasing: b[start..<end])) })
            }
        }
    }

    /// The value a record holds, as the model's word for it. The second answer is true when the record named a
    /// formula that could not be turned back into text — the cached value came back in its place.
    static func value(_ s: CellStorage, row: Int, col: Int, strings: [Int: String], formulas: [Int: ProtoMessage],
                      richTexts: [Int: RichText], decoder: inout NumbersFormulaDecoder, dataOnly: Bool) -> (value: CellValue?, undecodedFormula: Bool) {
        var value: CellValue?
        switch s.cellType {
        case .generic, .span: value = nil
        case .number, .currency:
            if let i = s.integer { value = .integer(i) }
            else if let d = s.decimal { value = .number(d) }
            else if let d = s.double { value = CellValue(d) }
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
        case .automatic:
            if let rich = s.richID.flatMap({ richTexts[$0] }), !rich.runs.isEmpty { value = .richText(rich.runs) }
            else { value = (s.richID.flatMap { richTexts[$0]?.text } ?? s.stringID.flatMap { strings[$0] }).map { .text($0) } }
        case .formula: value = nil
        }
        if let fid = s.formulaID, !dataOnly, let archive = formulas[fid] {
            if let text = decoder.text(for: archive, row: row, col: col) {
                return (.formula(FormulaExpr.parse(text, dialect: .xlsx), cached: value), false)
            }
            return (value, true)
        }
        return (value, false)
    }

    /// The table's rich-text list: the text, the links its smart fields carry (Numbers puts a hyperlink on a run of
    /// characters; the model has one link per cell, so the first one wins and the rest are reported) and the runs.
    static func richTexts(store: ProtoMessage, doc: any NumbersObjectStore, styles: NumbersStyleResolver) -> [Int: RichText] {
        dataList(store.reference("rich_text_table"), doc: doc) { entry -> RichText? in
            guard let payload = entry.reference("rich_text_payload"), let storageID = doc.object(payload)?.reference("storage"),
                  let storage = doc.object(storageID) else { return nil }
            let links = storage.message("table_smartfield")?.messages("entries").compactMap { field -> String? in
                guard let id = field.reference("object"), doc.typeName(id) == "TSWP.HyperlinkFieldArchive" else { return nil }
                return doc.object(id)?.string("url_ref")
            } ?? []
            let text = storage.strings("text").joined()
            return (text, links, runs(in: text, of: storage, styles: styles, doc: doc))
        }
    }

    /// The runs of a cell's text that carry formatting of their own. Numbers records where each run starts and
    /// the character style it uses; an entry with no style is back to the cell's own formatting.
    static func runs(in text: String, of storage: ProtoMessage, styles: NumbersStyleResolver, doc: any NumbersObjectStore) -> [TextRun] {
        let entries = storage.message("table_char_style")?.messages("entries") ?? []
        // One style over the whole text is the cell's own formatting, not a run of something different inside it
        // — Numbers writes it that way for any imported cell that has a font. Reading it as rich text turned
        // plain text into a one-run `.richText`, which is a different kind of value for no reason.
        guard entries.count > 1 else { return [] }
        let characters = Array(text)
        var out: [TextRun] = []
        for (i, entry) in entries.enumerated() {
            let start = Swift.min(entry.int("character_index") ?? 0, characters.count)
            let end = i + 1 < entries.count ? Swift.min(entries[i + 1].int("character_index") ?? characters.count, characters.count) : characters.count
            guard end > start else { continue }
            // the style a link wears is Numbers' own, not formatting the author asked for
            let object = entry.reference("object")
            let isLinkStyle = object.map { NumbersReader.isHyperlinkStyle($0, doc: doc) } ?? false
            let font = isLinkStyle ? nil : object.flatMap { styles.font(ofCharacterStyle: $0) }
            out.append(TextRun(String(characters[start..<end]), font: font))
        }
        return out.count > 1 || out.first?.font != nil ? out : []
    }

    /// The tiles of a table's data store in row order — by `tileid`, each covering `tileSize` rows — as
    /// (first row, tile object id).
    static func tiles(of store: ProtoMessage) -> (tileSize: Int, tiles: [(base: Int, id: Int)]) {
        let tiles = store.message("tiles")
        let tileSize = tiles?.int("tile_size").flatMap { $0 > 0 ? $0 : nil } ?? 256
        let refs = (tiles?.messages("tiles") ?? []).compactMap { ref -> (base: Int, id: Int)? in
            guard let id = ref.reference("tile") else { return nil }
            return ((ref.int("tileid") ?? 0) * tileSize, id)
        }
        return (tileSize, refs)
    }
}
