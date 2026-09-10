import Foundation
import SheetCore

/// The text of one table cell as ODF spells it: paragraphs (`text:p`), formatting runs (`text:span`), the
/// white-space rules of ODF 6.1.2, the links hung on runs (`text:a`), and the note (`office:annotation`) whose
/// paragraphs must not become the cell's own. The whole-workbook reader (`ContentParser`) and the streaming
/// reader (`ODSStreamingParser`) feed it the same events, so a cell reads the same by either road
/// (spec Appendix B.40.2).
struct ODSCellText {
    private(set) var paragraphs: [String] = []
    /// The runs of the cell's text, when a paragraph carried `text:span` children or links on part of it; empty otherwise.
    private(set) var runs: [(text: String, style: String?, link: Hyperlink?)] = []
    /// Every `xlink:href` in the cell, in document order. The model keeps one per cell; the reader reports the rest.
    private(set) var hyperlinks: [Hyperlink] = []
    private(set) var noteParagraphs: [String] = []
    private(set) var noteAuthor = ""
    /// The cell carried an `office:annotation`, even an empty one.
    private(set) var hasNote = false

    private var spanStyle: String?
    private var spanDepth = 0
    private var currentLink: Hyperlink?   // inside a `text:a` (B.81)
    private var runStart = 0
    private var paragraph = ""
    private var inParagraph = false
    private var lastWasCollapsibleSpace = true
    private var inAnnotation = false
    private var inCreator = false

    init() {}

    mutating func reset() { self = ODSCellText() }

    /// The cell's text, paragraphs joined by a line break.
    var text: String { paragraphs.joined(separator: "\n") }
    var isEmpty: Bool { paragraphs.isEmpty }
    /// True when any run names a style — the cell's text is formatted in parts.
    var hasStyledRuns: Bool { runs.contains { $0.style != nil } }
    /// True when the links sit on parts of the text and there is more than one: only rich text can carry them (B.81).
    var hasRunLinks: Bool { hyperlinks.count > 1 && runs.contains { $0.link != nil } }

    /// Takes a start tag inside a cell; false when the element is not part of the cell's text (a sub-table, a
    /// frame, the detective) and the caller should handle it.
    mutating func start(_ name: String, _ a: [String: String]) -> Bool {
        switch name {
        case "p":
            inParagraph = true; paragraph = ""; lastWasCollapsibleSpace = true
            if !runs.isEmpty { runs.append(("\n", nil, nil)) }
            runStart = runs.count
        case "span":
            guard inParagraph, !inAnnotation else { return true }
            spanDepth += 1
            if spanDepth == 1 {
                if !paragraph.isEmpty { runs.append((paragraph, nil, currentLink)); paragraph = "" }
                spanStyle = ODSAttr.get(a, "text:style-name")
            }
        case "s":
            guard inParagraph else { return true }
            appendLiteral(String(repeating: " ", count: Swift.max(1, ODSAttr.int(a, "text:c") ?? 1)))
        case "tab": if inParagraph { appendLiteral("\t") }
        case "line-break": if inParagraph { appendLiteral("\n") }
        case "a":
            guard inParagraph, !inAnnotation, let href = ODSAttr.get(a, "xlink:href") else { return true }
            let link = href.hasPrefix("#") ? Hyperlink(target: ContentParser.internalTarget(String(href.dropFirst())), isInternal: true) : Hyperlink(target: href)
            hyperlinks.append(link)
            // a link's edges are run edges: the text before it is a run of its own (B.81)
            if !paragraph.isEmpty { runs.append((paragraph, spanDepth > 0 ? spanStyle : nil, currentLink)); paragraph = "" }
            currentLink = link
        case "annotation": inAnnotation = true; hasNote = true
        case "creator":
            guard inAnnotation else { return true }
            inCreator = true; noteAuthor = ""
        default: return false
        }
        return true
    }

    mutating func text(_ s: String) {
        if inCreator { noteAuthor += s; return }
        guard inParagraph, !s.isEmpty else { return }
        // ODF 6.1.2: character-data white space collapses to one space, and leading white space is ignored
        let scalars = s.unicodeScalars
        if !scalars.contains(where: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
            paragraph += s; lastWasCollapsibleSpace = false; return
        }
        var out = String.UnicodeScalarView()
        for ch in scalars {
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                if lastWasCollapsibleSpace { continue }
                out.append(" "); lastWasCollapsibleSpace = true
            } else {
                out.append(ch); lastWasCollapsibleSpace = false
            }
        }
        paragraph += String(out)
    }

    private mutating func appendLiteral(_ s: String) { paragraph += s; lastWasCollapsibleSpace = false }

    /// Takes an end tag inside a cell; false when the element is not the text's.
    mutating func end(_ name: String) -> Bool {
        switch name {
        case "p":
            guard inParagraph else { return true }
            inParagraph = false
            if inAnnotation { noteParagraphs.append(paragraph); return true }
            if !runs.isEmpty {
                if !paragraph.isEmpty { runs.append((paragraph, nil, currentLink)) }
                paragraphs.append(runs[runStart...].reduce("") { $0 + $1.text })
                paragraph = ""
                return true
            }
            paragraphs.append(paragraph)
        case "span":
            guard inParagraph, spanDepth > 0 else { return true }
            spanDepth -= 1
            if spanDepth == 0 { runs.append((paragraph, spanStyle, currentLink)); paragraph = ""; spanStyle = nil }
        case "a":
            guard inParagraph, currentLink != nil else { return true }
            if !paragraph.isEmpty { runs.append((paragraph, spanDepth > 0 ? spanStyle : nil, currentLink)); paragraph = "" }
            currentLink = nil
        case "creator": inCreator = false
        case "annotation": inAnnotation = false
        case "s", "tab", "line-break": break
        default: return false
        }
        return true
    }

    /// The runs as rich text, each run's font taken from the style it names.
    func richText(font: (String) -> Font?) -> CellValue {
        .richText(runs.map { run in
            TextRun(run.text, font: run.style.flatMap(font), hyperlink: hyperlinks.count > 1 ? run.link : nil)
        })
    }

    /// The cell's value from its attributes and its text (spec §8): the typed `office:value` when there is one,
    /// the text otherwise, an error when the text spells one.
    func value(from a: [String: String], lenient: Bool) -> CellValue? {
        let text = self.text
        let isErrorText = CellValue.errorCodes.contains(text)
        if a["calcext:value-type"] == "error" { return .error(isErrorText ? text : (text.isEmpty ? "#VALUE!" : text)) }
        switch ODSAttr.get(a, "office:value-type", lenient: lenient) {
        case "float", "percentage", "currency":
            guard let v = ODSAttr.get(a, "office:value", lenient: lenient) else { return paragraphs.isEmpty ? nil : .text(text) }
            return ContentParser.number(v) ?? (paragraphs.isEmpty ? nil : .text(text))
        case "boolean":
            let v = ODSAttr.get(a, "office:boolean-value")?.lowercased()
            return .bool(v == "true" || v == "1")
        case "date":
            guard let v = ODSAttr.get(a, "office:date-value") else { return nil }
            return ContentParser.date(v) ?? .text(v)
        case "time":
            guard let v = ODSAttr.get(a, "office:time-value") else { return nil }
            return ContentParser.time(v) ?? .text(v)
        case "string":
            if isErrorText { return .error(text) }
            if let sv = ODSAttr.get(a, "office:string-value") { return .text(sv) }
            return .text(text)
        default:
            // no type: Excel-style producers sometimes omit it for text
            if paragraphs.isEmpty { return nil }
            return isErrorText ? .error(text) : .text(text)
        }
    }
}
