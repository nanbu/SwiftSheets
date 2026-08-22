import Foundation
import SheetCore

/// Cell notes, the two-part way OOXML stores them: the text lives in `xl/comments*.xml`, and every note also needs a
/// shape in a *legacy VML drawing* — the 1998 vector format Excel still requires for the little yellow box. A
/// comments part without its VML opens, but the note is invisible and Excel offers to repair the file.
///
/// Written from ECMA-376 Part 1 §18.7 (comments) and Part 4 §14.1 (the VML subset Office uses); the shape below is
/// the minimum Excel and LibreOffice both accept. Appendix B.7 listed this as未着手 — a note read from an ODS file
/// or set in code was dropped with a warning when writing .xlsx.
enum CommentParts {
    static let relationshipType = "/comments"
    static let vmlRelationshipType = "/vmlDrawing"
    static let contentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.comments+xml"
    static let vmlContentType = "application/vnd.openxmlformats-officedocument.vmlDrawing"

    // MARK: - Reading

    static func parse(_ data: Data, part: String) -> [CellRef: CellNote] {
        let parser = CommentsParser()
        try? parser.run(data, part: part)
        return parser.notes
    }

    /// The note sizes live in the VML, not in the comments part. Anything the shape does not say keeps the default.
    static func applySizes(from vml: Data, to notes: inout [CellRef: CellNote]) {
        for shape in VMLShapes.notes(in: String(decoding: vml, as: UTF8.self)) {
            guard let ref = shape.ref, notes[ref] != nil else { continue }
            if let w = shape.width { notes[ref]!.width = w }
            if let h = shape.height { notes[ref]!.height = h }
        }
    }

    /// True when the VML holds shapes that are not notes — form controls, buttons, drop-downs. Regenerating the
    /// part would drop them, so the writer says so rather than losing them quietly.
    static func holdsNonNoteShapes(_ vml: Data) -> Bool {
        let text = String(decoding: vml, as: UTF8.self)
        let clientData = text.components(separatedBy: "ClientData").count - 1
        let notes = text.components(separatedBy: "ObjectType=\"Note\"").count - 1
        // every ClientData element appears twice (open and close tag); a Note is named once
        return clientData / 2 > notes
    }

    // MARK: - Writing

    static func commentsXML(_ notes: [(ref: CellRef, note: CellNote)]) -> String {
        var authors: [String] = []
        for (_, note) in notes where !authors.contains(note.author) { authors.append(note.author) }
        if authors.isEmpty { authors = [""] }
        var s = "<comments xmlns=\"\(XMLWriter.nsMain)\"><authors>"
        s += authors.map { "<author>\(XML.esc($0))</author>" }.joined()
        s += "</authors><commentList>"
        for (ref, note) in notes {
            let author = authors.firstIndex(of: note.author) ?? 0
            s += "<comment ref=\"\(ref.a1)\" authorId=\"\(author)\" shapeId=\"0\"><text><t xml:space=\"preserve\">\(XML.esc(note.text))</t></text></comment>"
        }
        return s + "</commentList></comments>"
    }

    /// One `v:shape` per note, anchored to its cell by `x:Row` / `x:Column`. Shapes are hidden until the reader
    /// hovers, which is what `visibility:hidden` says; Excel supplies the position from the anchor.
    static func vmlXML(_ notes: [(ref: CellRef, note: CellNote)]) -> String {
        var s = "<xml xmlns:v=\"urn:schemas-microsoft-com:vml\" xmlns:o=\"urn:schemas-microsoft-com:office:office\""
        s += " xmlns:x=\"urn:schemas-microsoft-com:office:excel\">"
        s += "<o:shapelayout v:ext=\"edit\"><o:idmap v:ext=\"edit\" data=\"1\"/></o:shapelayout>"
        s += "<v:shapetype id=\"_x0000_t202\" coordsize=\"21600,21600\" o:spt=\"202\" path=\"m,l,21600r21600,l21600,xe\">"
        s += "<v:stroke joinstyle=\"miter\"/><v:path gradientshapeok=\"t\" o:connecttype=\"rect\"/></v:shapetype>"
        for (i, entry) in notes.enumerated() {
            s += "<v:shape id=\"_x0000_s\(1026 + i)\" type=\"#_x0000_t202\""
            s += " style=\"position:absolute;margin-left:59.25pt;margin-top:1.5pt;width:\(XML.num(entry.note.width))px;height:\(XML.num(entry.note.height))px;z-index:\(i + 1);visibility:hidden\""
            s += " fillcolor=\"#ffffe1\" o:insetmode=\"auto\">"
            s += "<v:fill color2=\"#ffffe1\"/><v:shadow color=\"black\" obscured=\"t\"/><v:path o:connecttype=\"none\"/>"
            s += "<v:textbox style=\"mso-direction-alt:auto\"><div style=\"text-align:left\"/></v:textbox>"
            s += "<x:ClientData ObjectType=\"Note\"><x:MoveWithCells/><x:SizeWithCells/><x:AutoFill>False</x:AutoFill>"
            s += "<x:Row>\(entry.ref.row)</x:Row><x:Column>\(entry.ref.col)</x:Column></x:ClientData></v:shape>"
        }
        return s + "</xml>"
    }
}

/// `xl/comments*.xml` → notes by cell. Rich text inside a note is flattened: `CellNote.text` is plain text, the way
/// openpyxl's `Comment.text` is.
final class CommentsParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    var notes: [CellRef: CellNote] = [:]
    private var authors: [String] = []
    private var inAuthor = false
    private var author = ""
    private var ref: CellRef?
    private var authorID = 0
    private var text = ""
    private var inText = false

    func start(_ name: String, _ a: [String: String]) {
        switch name {
        case "author": inAuthor = true; author = ""
        case "comment":
            ref = a["ref"].flatMap { CellRef($0) } ?? CellRange(a["ref"] ?? "").map { CellRef(row: $0.minRow, col: $0.minCol) }
            authorID = Int(a["authorId"] ?? "0") ?? 0
            text = ""
        case "text": inText = true
        default: break
        }
    }

    func text(_ s: String) {
        if inAuthor { author += s } else if inText { text += s }
    }

    func end(_ name: String) {
        switch name {
        case "author": authors.append(author); inAuthor = false
        case "text": inText = false
        case "comment":
            defer { ref = nil }
            guard let ref else { return }
            notes[ref] = CellNote(text, author: authors.indices.contains(authorID) ? authors[authorID] : "")
        default: break
        }
    }
}

/// The little that has to be read back out of a legacy VML drawing: which cell a note shape sits on and how big its
/// box is. Parsing VML properly is a project of its own, and nothing else about the shape is worth keeping — the
/// writer regenerates it.
enum VMLShapes {
    struct Note { var ref: CellRef?; var width: Double?; var height: Double? }

    /// Note sizes are in pixels, as openpyxl's `Comment(width:height:)` are.
    static func notes(in vml: String) -> [Note] {
        var out: [Note] = []
        for shape in shapes(in: vml) {
            guard let marker = shape.range(of: "ObjectType=\"Note\"") else { continue }
            let style = shape[..<marker.lowerBound]
            let anchor = shape[marker.upperBound...]
            guard let row = integer(after: "Row>", in: anchor), let col = integer(after: "Column>", in: anchor) else {
                out.append(Note(ref: nil, width: nil, height: nil)); continue
            }
            out.append(Note(ref: CellRef(row: row, col: col), width: pixels("width:", in: style), height: pixels("height:", in: style)))
        }
        return out
    }

    /// Every `<…:shape …>…</…:shape>`. The namespace prefix is the writer's choice ("v:" from Excel, "ns1:" from
    /// openpyxl), so the tag is matched by its local name.
    private static func shapes(in vml: String) -> [Substring] {
        var out: [Substring] = []
        var rest = Substring(vml)
        while let open = rest.range(of: ":shape ") {
            rest = rest[open.upperBound...]
            let end = rest.range(of: ":shape>")?.lowerBound ?? rest.endIndex
            out.append(rest[..<end])
            rest = rest[end...]
        }
        return out
    }

    private static func integer(after marker: String, in s: Substring) -> Int? {
        guard let r = s.range(of: marker) else { return nil }
        return Int(s[r.upperBound...].prefix { $0.isNumber })
    }

    /// `width:200px` — the value up to the next `;`, in pixels (a `pt` length is 96/72 of one).
    private static func pixels(_ marker: String, in s: Substring) -> Double? {
        guard let r = s.range(of: marker) else { return nil }
        let field = s[r.upperBound...].prefix { $0 != ";" && $0 != "\"" }
        guard let value = Double(field.prefix { $0.isNumber || $0 == "." }) else { return nil }
        return field.hasSuffix("pt") ? value * 96 / 72 : value
    }
}
