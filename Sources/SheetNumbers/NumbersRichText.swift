import Foundation
import SheetCore

/// What Numbers keeps inside one cell beyond its value: a link, formatting that changes part-way through the
/// text, and a note (spec Appendix B.18).
///
/// A cell that carries any of these holds no plain string. It names an entry of its table's **rich-text list**,
/// which points at a `TST.RichTextPayloadArchive`, which points at a `TSWP.StorageArchive` — the same text
/// engine Pages uses. The text is there; a link is a *smart field* over a run of characters, and a change of
/// font is a *character style* over another. A note is separate again: an entry of the table's **comment list**,
/// pointing at a `TSD.CommentStorageArchive` with the text and its author.
///
/// The shapes are the ones Numbers 15.3.1 wrote when it imported an `.xlsx` carrying the same four things.
enum NumbersRichText {
    /// One of the template's own character styles, by the identifier Numbers gives it. `character-style-null` is
    /// the plain one every run varies from; `character-style-hyperlink` is what a link looks like.
    static func templateCharacterStyle(_ identifier: String, in doc: NumbersDocument) -> Int? {
        doc.identifiers(ofType: "TSWP.CharacterStyleArchive").first {
            doc.object($0)?.message("super")?.string("style_identifier") == identifier
        }
    }

    /// The first list style the template carries — cell text is one unnumbered paragraph, but Numbers still
    /// names a list style for it.
    static func templateListStyle(in doc: NumbersDocument) -> Int? {
        doc.identifiers(ofType: "TSWP.ListStyleArchive").sorted().first
    }

    /// The text engine's archive for one cell.
    /// - Parameters:
    ///   - runs: where each run of its own formatting starts, and the character style it uses (nil = back to plain).
    ///   - fields: where a smart field starts, and the object it points at (a hyperlink).
    static func storage(text: String, stylesheet: Int?, paragraphStyle: Int?, listStyle: Int?,
                        runs: [(index: Int, style: Int?)], fields: [(index: Int, object: Int)]) -> ProtoMessage {
        var storage = ProtoMessage(typeName: "TSWP.StorageArchive")
        storage.set("kind", int: NumbersSchema.shared.enums["TSWP.StorageArchive.KindType"]?["CELL"] ?? 5)
        if let stylesheet { storage.set("style_sheet", reference: stylesheet) }
        storage.set("text", string: text)
        // Numbers writes the paragraph tables even for a single line of cell text, and will not open a document
        // whose cell storage lacks them — found by asking it (Appendix B.18).
        if let paragraphStyle { storage.set("table_para_style", message: attributeTable([(0, paragraphStyle)])) }
        storage.set("table_para_data", message: paragraphData())
        if let listStyle { storage.set("table_list_style", message: attributeTable([(0, listStyle)])) }
        if !runs.isEmpty { storage.set("table_char_style", message: attributeTable(runs.map { ($0.index, $0.style) })) }
        storage.set("in_document", bool: true)
        if !fields.isEmpty { storage.set("table_smartfield", message: attributeTable(fields.map { ($0.index, Optional($0.object)) })) }
        storage.set("table_para_starts", message: paragraphData())
        return storage
    }

    private static func paragraphData() -> ProtoMessage {
        var table = ProtoMessage(typeName: "TSWP.ParaDataAttributeTable")
        var entry = ProtoMessage(typeName: "TSWP.ParaDataAttributeTable.ParaDataAttribute")
        entry.set("character_index", int: 0); entry.set("first", int: 0); entry.set("second", int: 0)
        table.set("entries", messages: [entry])
        return table
    }

    /// A link over a run of characters. Numbers gives every one its own UUID string.
    static func hyperlink(_ url: String) -> ProtoMessage {
        var field = ProtoMessage(typeName: "TSWP.HyperlinkFieldArchive")
        var sup = ProtoMessage(typeName: "TSWP.SmartFieldArchive")
        sup.set("text_attribute_uuid_string", string: UUID().uuidString)
        field.set("super", message: sup)
        field.set("url_ref", string: url)
        return field
    }

    /// The payload the list entry names. `cellid` is the "no particular cell" value Numbers writes.
    static func payload(storage id: Int) -> ProtoMessage {
        var payload = ProtoMessage(typeName: "TST.RichTextPayloadArchive")
        payload.set("storage", reference: id)
        var cell = ProtoMessage(typeName: "TST.CellID")
        cell.set("packedData", int: 0xFF_FFFF)
        var coord = ProtoMessage(typeName: "TSCE.CellCoordinateArchive")
        coord.set("column", int: 0x7FFF)
        coord.set("row", int: 0x7FFF_FFFF)
        cell.set("expanded_coord", message: coord)
        payload.set("cellid", message: cell)
        return payload
    }

    /// A note: its text, and the author it belongs to.
    static func comment(_ note: CellNote, author: Int?) -> ProtoMessage {
        var archive = ProtoMessage(typeName: "TSD.CommentStorageArchive")
        archive.set("text", string: note.text)
        if let author { archive.set("author", reference: author) }
        archive.set("storage_uuid", message: NumbersUUID.random().uuid)
        return archive
    }

    /// A person a note belongs to. Numbers colours each author's notes; the yellow is the one it uses itself.
    static func author(named name: String) -> ProtoMessage {
        var archive = ProtoMessage(typeName: "TSK.AnnotationAuthorArchive")
        archive.set("name", string: name)
        var colour = ProtoMessage(typeName: "TSP.Color")
        colour.set("model", int: 1)
        colour.set("r", float: 0.980_392_16); colour.set("g", float: 0.937_254_9); colour.set("b", float: 0.352_941_2)
        colour.set("a", float: 1); colour.set("rgbspace", int: 1)
        archive.set("color", message: colour)
        archive.set("is_public_author", bool: false)
        return archive
    }

    private static func attributeTable(_ entries: [(index: Int, object: Int?)]) -> ProtoMessage {
        var table = ProtoMessage(typeName: "TSWP.ObjectAttributeTable")
        var list: [ProtoMessage] = []
        for entry in entries.sorted(by: { $0.index < $1.index }) {
            var m = ProtoMessage(typeName: "TSWP.ObjectAttributeTable.ObjectAttribute")
            m.set("character_index", int: entry.index)
            if let object = entry.object { m.set("object", reference: object) }
            list.append(m)
        }
        table.set("entries", messages: list)
        return table
    }
}
