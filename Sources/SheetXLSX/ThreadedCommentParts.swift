import Foundation
import SheetCore

/// Threaded comments, the way Excel 2019+ stores them (spec Appendix B.80): one `xl/threadedComments/
/// threadedCommentN.xml` per sheet (each comment with its cell, author id, time, `done`, and `parentId` for a
/// reply), one `xl/persons/person.xml` for the workbook (id → display name), and — for readers that predate
/// threads — a legacy note per thread whose text begins "[Threaded comment]" and whose author is `tc={id}`.
enum ThreadedCommentParts {
    static let relationshipType = "http://schemas.microsoft.com/office/2017/10/relationships/threadedComment"
    static let personRelationshipType = "http://schemas.microsoft.com/office/2017/10/relationships/person"
    static let contentType = "application/vnd.ms-excel.threadedcomments+xml"
    static let personContentType = "application/vnd.ms-excel.person+xml"
    static let ns = "http://schemas.microsoft.com/office/spreadsheetml/2018/threadedcomments"
    static let personsPath = "xl/persons/person.xml"

    // MARK: - Reading

    /// `xl/persons/person.xml` → id → display name.
    static func persons(_ data: Data, part: String) -> [String: String] {
        let parser = PersonParser()
        try? parser.run(data, part: part)
        return parser.persons
    }

    /// `xl/threadedComments/threadedCommentN.xml` → threads by cell: the comment without a parent opens the
    /// thread, the ones naming it as parent are its replies, in document order.
    static func parse(_ data: Data, part: String, persons: [String: String]) -> [CellRef: CommentThread] {
        let parser = ThreadedCommentParser()
        try? parser.run(data, part: part)
        var threads: [CellRef: CommentThread] = [:]
        var rootIDs: [String: CellRef] = [:]
        for c in parser.comments where c.parentID == nil {
            var t = CommentThread(c.text, author: persons[c.personID] ?? c.personID, created: c.created)
            t.resolved = c.done
            threads[c.ref] = t
            rootIDs[c.id] = c.ref
        }
        for c in parser.comments {
            guard let parent = c.parentID, let ref = rootIDs[parent] else { continue }
            threads[ref]?.replies.append(CommentThread.Reply(c.text, author: persons[c.personID] ?? c.personID, created: c.created))
        }
        return threads
    }

    // MARK: - Writing

    /// A stable id for a person (the same name gets the same id on every write).
    static func personID(_ name: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in name.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let hex = String(format: "%016llX", h)
        return "{" + hex.prefix(8) + "-" + hex.dropFirst(8).prefix(4) + "-4" + hex.dropFirst(12).prefix(3) + "-8000-" + String(format: "%012llX", h & 0xFFFFFFFFFFFF) + "}"
    }

    static func personsXML(_ persons: [(id: String, name: String)]) -> String {
        var s = "<personList xmlns=\"\(ns)\" xmlns:x=\"\(XMLWriter.nsMain)\">"
        for p in persons {
            s += "<person displayName=\"\(XML.esc(p.name))\" id=\"\(XML.esc(p.id))\" userId=\"\(XML.esc(p.name))\" providerId=\"None\"/>"
        }
        return s + "</personList>"
    }

    /// The thread parts of one sheet and the mirror notes the legacy comments part needs beside the sheet's own.
    /// Ids are fresh GUIDs — Excel does the same on every save.
    static func threadedCommentsXML(_ threads: [(ref: CellRef, thread: CommentThread)], personID: (String) -> String) -> (xml: String, mirrors: [(ref: CellRef, note: CellNote)]) {
        var s = "<ThreadedComments xmlns=\"\(ns)\" xmlns:x=\"\(XMLWriter.nsMain)\">"
        var mirrors: [(ref: CellRef, note: CellNote)] = []
        func guid() -> String { "{" + UUID().uuidString + "}" }
        let now: CivilDateTime = {
            // UTC, by arithmetic on the epoch seconds: no Calendar, no TimeZone
            let seconds = Int(Date().timeIntervalSince1970.rounded(.down))
            let days = seconds >= 0 ? seconds / 86_400 : -((-seconds + 86_399) / 86_400)
            let rest = seconds - days * 86_400
            return CivilDateTime(date: CivilDate(dayNumber: days), time: TimeOfDay(hour: rest / 3600, minute: (rest % 3600) / 60, second: rest % 60))
        }()
        func time(_ d: CivilDateTime?) -> String { let t = d ?? now; return t.iso8601 + (t.time.nanosecond == 0 ? ".00" : "") }
        for (ref, thread) in threads {
            let id = guid()
            s += "<threadedComment ref=\"\(ref.address)\" dT=\"\(time(thread.created))\" personId=\"\(personID(thread.author))\" id=\"\(id)\"\(thread.resolved ? " done=\"1\"" : "")>"
            s += "<text>\(XML.esc(thread.text))</text></threadedComment>"
            for r in thread.replies {
                s += "<threadedComment ref=\"\(ref.address)\" dT=\"\(time(r.created))\" personId=\"\(personID(r.author))\" id=\"\(guid())\" parentId=\"\(id)\">"
                s += "<text>\(XML.esc(r.text))</text></threadedComment>"
            }
            var mirror = CommentThread.mirrorPrefix + "\n\nYour version of Excel allows you to read this threaded comment; however, any edits to it will get removed if the file is opened in a newer version of Excel. Learn more: https://go.microsoft.com/fwlink/?linkid=870924\n\nComment:\n    " + thread.text
            for r in thread.replies { mirror += "\nReply:\n    " + r.text }
            mirrors.append((ref, CellNote(mirror, author: "tc=" + id)))
        }
        return (s + "</ThreadedComments>", mirrors)
    }
}

final class PersonParser: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    var persons: [String: String] = [:]
    func start(_ name: String, _ a: [String: String]) {
        if name == "person", let id = a["id"] { persons[id] = a["displayName"] ?? a["userId"] ?? "" }
    }
    func text(_ s: String) {}
    func end(_ name: String) {}
}

final class ThreadedCommentParser: SAXHandler {
    struct Comment { var ref: CellRef; var id: String; var parentID: String?; var personID: String; var created: CivilDateTime?; var done: Bool; var text: String }
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    var comments: [Comment] = []
    private var current: Comment?
    private var inText = false
    private var depthInText = 0
    func start(_ name: String, _ a: [String: String]) {
        switch name {
        case "threadedComment":
            guard let ref = a["ref"].flatMap({ CellRef($0) }) else { return }
            current = Comment(ref: ref, id: a["id"] ?? "", parentID: a["parentId"], personID: a["personId"] ?? "",
                              created: a["dT"].flatMap { CivilDateTime(iso8601: $0) }, done: XMLBool.isTrue(a["done"]), text: "")
        case "text" where current != nil && !inText: inText = true
        default: break
        }
    }
    func text(_ s: String) { if inText { current?.text += s } }
    func end(_ name: String) {
        switch name {
        case "text" where inText: inText = false
        case "threadedComment": if let c = current { comments.append(c) }; current = nil
        default: break
        }
    }
}
