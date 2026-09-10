import Foundation

/// Everything a reader saw but did not interpret, kept so that writing the same format back loses nothing (fidelity
/// level F3, spec §6): charts, drawings, pivot caches, VBA, custom XML, themes — as bytes, with their relationships
/// and content types. Converting to another format cannot carry these; the writer lists them as `dropped` warnings.
package struct PreservationStore: Sendable, Hashable {
    package var sourceFormat: SheetFormat?
    /// `xl/persons/person.xml` as read: person id → display name (B.80), so a same-family write can keep the ids.
    package var persons: [String: String] = [:]
    /// Uninterpreted parts by package path ("xl/charts/chart1.xml", "xl/vbaProject.bin"), bytes untouched.
    ///
    /// Reading this expands every part a reader kept compressed (spec Appendix B.39.7); it is the view for a
    /// caller who wants the bytes. The writers do not go through it — they copy a compressed part into the new
    /// package as it lies, without expanding it or folding it again.
    package var opaqueParts: [String: Data] {
        get { parts.mapValues(\.data) }
        set { parts = newValue.mapValues { .bytes($0) } }
    }
    /// The parts as the reader kept them: expanded, or still folded as they were in the source package.
    package var parts: [String: OpaquePart] = [:]
    /// The names of the parts, without expanding any of them.
    package var opaquePartNames: [String] { Array(parts.keys) }
    package var opaquePartCount: Int { parts.count }
    /// `[Content_Types].xml` entries of the source: extension defaults and part overrides, so opaque parts keep
    /// their declarations when re-packed.
    package var contentTypeDefaults: [String: String] = [:]
    package var contentTypeOverrides: [String: String] = [:]
    /// Relationships of interpreted parts that point at opaque parts, keyed by the source part's path. Their ids
    /// are immutable: new relationships are numbered from the highest existing id + 1.
    package var relationships: [String: [Relationship]] = [:]
    /// Unknown children of `<workbook>` in document order (`extLst`, `pivotCaches`, `externalReferences`, …).
    package var workbookFragments: [XMLFragment] = []
    /// Attributes of the `<workbook>` root element (namespace declarations, `mc:Ignorable`) — needed so fragments
    /// that use those prefixes stay well-formed.
    package var workbookRootAttributes: [String: String] = [:]
    /// Attributes of `<workbookPr>` other than the ones the model owns.
    package var workbookPrAttributes: [String: String] = [:]
    /// The attributes of `<calcPr>` as the source file had them. The writer regenerates the element from the
    /// model's calculation settings and carries the rest of these along (spec Appendix B.40.4).
    package var calcPrAttributes: [String: String] = [:]
    /// Parts of styles.xml that index-reference each other and must be re-emitted verbatim (`tableStyles`,
    /// `cellStyles`, `cellStyleXfs`, `extLst`), plus the source style tables in their original order.
    package var styleFragments: [XMLFragment] = []
    package var styleTables: StyleTables?
    /// The generating application's declared name / version (docProps/app.xml), informational.
    package var application: String?
    /// The source's shared-string table, kept only when a sheet was left unread (`ReadOptions.sheets`): the
    /// unread sheet's cells name their text by index into it, so the writer starts the table with these entries
    /// in their order and appends after them (spec Appendix B.39.10).
    package var sharedStrings: [CellValue]?
    /// The phonetic guides of `sharedStrings`, entry by entry (nil where a string has none).
    package var sharedStringPhonetics: [PhoneticText?]?
    /// The theme as read from the source's theme part: while `Workbook.theme` still equals it, the part is written
    /// back byte for byte; once it differs, the part is regenerated from the model (B.71).
    package var theme: Theme?

    package init() {}

    package var isEmpty: Bool { parts.isEmpty && workbookFragments.isEmpty && styleFragments.isEmpty }

    /// Whether a VBA project rides along among the preserved parts.
    ///
    /// Only a macro-enabled workbook can hold one, so every other target has to report it as `.macros` rather than
    /// fold it into a count of "parts": the subject is what decides which format `WriteResult.suggest` names, and a
    /// macro loss answered with "write XLSX instead" points at a format that loses them too (spec Appendix B.22).
    package var hasVBAProject: Bool { parts.keys.contains { $0.hasSuffix("vbaProject.bin") } }

    /// What the preserved material holds that the model does not represent, by kind (spec Appendix B.77).
    /// Parts the model read stay out (a sheet's drawing and what it referenced, the theme once read, the notes'
    /// comment parts); parts that belong to a counted one (relationships, a chart's style, a diagram's layout,
    /// an object's replacement image) are not counted twice.
    package func inventory(sheets: [Sheet], themeRead: Bool) -> [PreservedPartKind: Int] {
        var counts: [PreservedPartKind: Int] = [:]
        var modelled = Set<String>()
        for sheet in sheets {
            if let d = sheet.preserved.drawingPath { modelled.insert(d) }
            modelled.formUnion(sheet.preserved.drawingParts)
            // the notes' comments part and legacy VML are the model's (B.56, B.80)
            if !sheet.preserved.comments.isEmpty || !sheet.preserved.threads.isEmpty, let part = sheet.preserved.partPath {
                let dir = (part as NSString).deletingLastPathComponent
                for r in sheet.preserved.relationships where r.type.hasSuffix("/vmlDrawing") || r.type.hasSuffix("/comments") || r.type.hasSuffix("/threadedComment") {
                    modelled.insert(Self.resolved(r.target, relativeTo: dir))
                }
            }
            for object in sheet.preserved.drawingUnmodelled {
                switch object {
                case "SmartArt": break                                   // counted by its data part below
                case "a group of shapes": counts[.shapeGroup, default: 0] += 1
                default: counts[.drawingObject, default: 0] += 1
                }
            }
            if sheet.preserved.foreignSheet != nil { counts[.chartSheet, default: 0] += 1 }
        }
        for path in parts.keys where !path.contains("/_rels/") && !path.hasPrefix("_rels/") && !modelled.contains(path) {
            guard let kind = Self.kind(ofPart: path, themeRead: themeRead) else { continue }
            counts[kind, default: 0] += 1
        }
        return counts
    }

    /// "xl/worksheets" + "../drawings/vmlDrawing1.vml" → "xl/drawings/vmlDrawing1.vml".
    static func resolved(_ target: String, relativeTo base: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = base.split(separator: "/").map(String.init)
        for segment in target.split(separator: "/") {
            if segment == ".." { if !parts.isEmpty { parts.removeLast() } } else if segment != "." { parts.append(String(segment)) }
        }
        return parts.joined(separator: "/")
    }

    /// The kind a preserved part counts under; nil for one that belongs to a counted part or to the application.
    static func kind(ofPart path: String, themeRead: Bool) -> PreservedPartKind? {
        let name = (path as NSString).lastPathComponent
        if path.hasPrefix("xl/") {
            switch path {
            case _ where path.hasPrefix("xl/charts/"): return name.hasPrefix("chart") ? .chart : nil
            case _ where path.hasPrefix("xl/chartsheets/"): return nil                      // counted from the sheet
            case _ where path.hasPrefix("xl/drawings/"): return name.hasPrefix("commentsDrawing") ? nil : .drawing
            case _ where path.hasPrefix("xl/media/"): return .image
            case _ where path.hasPrefix("xl/diagrams/"): return name.hasPrefix("data") ? .smartArt : nil
            case "xl/vbaProject.bin": return .vbaProject
            case "xl/vbaProjectSignature.bin", "xl/vbaData.xml": return nil
            case _ where path.hasPrefix("xl/theme/"): return themeRead ? nil : .theme
            case _ where path.hasPrefix("xl/slicers/") || path.hasPrefix("xl/slicerCaches/"): return .slicer
            case "xl/connections.xml", _ where path.hasPrefix("xl/queryTables/") || path.hasPrefix("xl/model/"): return .dataConnection
            case _ where path.hasPrefix("xl/threadedComments/") || path.hasPrefix("xl/persons/"): return nil   // the threads are the model's (B.80)
            case _ where path.hasPrefix("xl/comments"): return nil                          // the notes are the model's
            case _ where path.hasPrefix("xl/embeddings/"): return .embeddedObject
            case _ where path.hasPrefix("xl/activeX/"): return name.hasSuffix(".xml") ? .embeddedObject : nil   // the .bin belongs to its .xml
            case _ where path.hasPrefix("xl/ctrlProps/"): return nil
            case _ where path.hasPrefix("xl/externalLinks/"): return .externalLink
            case _ where path.hasPrefix("xl/pivotCache/"): return name.hasPrefix("pivotCacheDefinition") ? .pivot : nil
            case _ where path.hasPrefix("xl/pivotTables/"): return .pivot
            case _ where path.hasPrefix("xl/tables/"): return .table
            case _ where path.hasPrefix("xl/printerSettings/"): return .printerSettings
            default: return .other
            }
        }
        if path.hasPrefix("customXml/") { return name.hasPrefix("item") && !name.hasPrefix("itemProps") ? .customXML : nil }
        // ODS
        if path.hasPrefix("Pictures/") { return .image }
        if path.hasPrefix("Object ") { return name == "content.xml" ? .embeddedObject : nil }
        if path.hasPrefix("ObjectReplacements/") || path.hasPrefix("Configurations2/") || path.hasPrefix("Thumbnails/") { return nil }
        if path.hasPrefix("Basic/") { return name.hasSuffix("-lc.xml") || name.hasSuffix("-lb.xml") ? nil : .script }
        return .other
    }

    /// Human-readable inventory: "VBA project: yes / charts: 2 / drawings: 1 / other parts: 3".
    package var summary: String {
        var counts: [(String, Int)] = []
        func count(_ label: String, _ predicate: (String) -> Bool) {
            let n = self.parts.keys.filter(predicate).count
            if n > 0 { counts.append((label, n)) }
        }
        let vba = hasVBAProject
        count("charts") { $0.hasPrefix("xl/charts/") && !$0.contains("/_rels/") }
        count("drawings") { $0.hasPrefix("xl/drawings/") && !$0.contains("/_rels/") && !$0.hasSuffix(".vml") }
        count("pivot tables") { $0.hasPrefix("xl/pivotTables/") && !$0.contains("/_rels/") }
        count("tables") { $0.hasPrefix("xl/tables/") }
        count("comments") { $0.hasPrefix("xl/comments") }
        count("images") { $0.hasPrefix("xl/media/") }
        let known = counts.reduce(0) { $0 + $1.1 } + (vba ? 1 : 0)
        let other = self.parts.count - known
        var parts = ["VBA project: \(vba ? "yes" : "no")"] + counts.map { "\($0.0): \($0.1)" }
        if other > 0 { parts.append("other parts: \(other)") }
        return parts.joined(separator: " / ")
    }
}

/// One part a reader did not interpret: its bytes, or — when it came out of a package — the folded bytes
/// exactly as the package held them, with what a writer needs to copy them into another package unchanged.
/// A same-format write then never expands a chart, an image or a VBA project it does not touch, and never
/// folds them again: "byte for byte" is literal, and the cost of carrying a part no longer depends on its size.
package enum OpaquePart: Sendable, Hashable {
    case bytes(Data)
    case compressed(payload: Data, method: UInt16, crc32: UInt32, uncompressedSize: Int)

    /// The part's bytes, expanded if they were folded.
    package var data: Data {
        switch self {
        case .bytes(let d): return d
        case .compressed(let payload, let method, _, let size):
            if method == 0 { return payload }
            return (try? Deflate.decompress(payload, expectedSize: size)) ?? Data()
        }
    }

    /// The expanded size, without expanding.
    package var uncompressedSize: Int {
        switch self { case .bytes(let d): return d.count; case .compressed(_, _, _, let n): return n }
    }
}

/// A raw XML element kept as text (the element's qualified name and its complete serialization).
package struct XMLFragment: Sendable, Hashable {
    package var element: String
    package var xml: String
    package init(element: String, xml: String) { self.element = element; self.xml = xml }
}

/// An OPC relationship (`<Relationship Id Type Target TargetMode>`).
package struct Relationship: Sendable, Hashable {
    package var id: String
    package var type: String
    package var target: String
    package var targetMode: String?
    package init(id: String, type: String, target: String, targetMode: String? = nil) {
        self.id = id; self.type = type; self.target = target; self.targetMode = targetMode
    }
    /// The numeric part of "rId12" (nil for other id shapes).
    package var number: Int? { id.hasPrefix("rId") ? Int(id.dropFirst(3)) : nil }
}

/// The style tables of a source styles.xml in their original order, so indices referenced by preserved fragments
/// (`cellStyleXfs`, `dxfs` via `tableStyles`) and by `<col style>` stay valid after a rewrite.
package struct StyleTables: Sendable, Hashable {
    package var fonts: [Font] = []
    package var fills: [Fill] = []
    package var borders: [Border] = []
    /// Custom number formats by id (ids ≥ 164).
    package var numberFormats: [Int: String] = [:]
    /// Raw `<font>` / `<fill>` / `<border>` elements, re-emitted verbatim in place of the parsed forms so attributes the
    /// model does not carry (gradient fills, condense/extend) survive.
    package var fontXML: [String] = []
    package var fillXML: [String] = []
    package var borderXML: [String] = []
    /// Attributes of the `<styleSheet>` root (namespace declarations used by preserved sections).
    package var rootAttributes: [String: String] = [:]
    /// `cellStyleXfs`, entry by entry: the raw `<xf>` and its parsed form. Named styles point into this table by
    /// index, so entries no `cellStyle` names have to be kept anyway — dropping one renumbers every entry after it.
    package var cellStyleXfXML: [String] = []
    package var cellStyleXfs: [CellStyle] = []
    /// Named style name → its index in `cellStyleXfs`, as the source file had it. Names the file already knew keep
    /// their index on a write-back; new ones are appended.
    package var namedStyleXfIndex: [String: Int] = [:]
    /// The source `cellXfs`, entry by entry. A sheet left unread names its formatting by index into this table,
    /// so a write-back that carries such a sheet keeps every entry at its index (spec Appendix B.39.10).
    package var cellXfs: [CellStyle] = []
    /// The differential formats (`<dxfs>`), parsed and raw. Conditional formats, tables and colour filters address
    /// them by index, so the source entries keep their positions and new ones are appended after them.
    package var dxfs: [DifferentialStyle] = []
    package var dxfXML: [String] = []
    package init() {}
}

/// Per-sheet preserved material (travels with the sheet so renames and moves keep it).
package struct SheetPreservation: Sendable, Hashable {
    /// The source part path ("xl/worksheets/sheet1.xml"), reused on write so opaque parts that name it stay valid.
    package var partPath: String?
    /// The workbook relationship id and `sheetId` the sheet had in the source.
    package var relationshipId: String?
    package var sheetId: Int?
    /// Unknown children of `<worksheet>` in document order (conditional formatting, data validation, drawings, tables, …).
    package var fragments: [XMLFragment] = []
    /// Relationships of the sheet part other than hyperlinks (drawing, comments, table, printerSettings, …).
    package var relationships: [Relationship] = []
    /// Attributes of the `<worksheet>` root element (namespace declarations, `mc:Ignorable`).
    package var rootAttributes: [String: String] = [:]
    /// `<pageSetup r:id>` — the printer-settings part the sheet was configured against. The part itself is opaque
    /// and its relationship is in `relationships`; without this attribute the link between them is lost.
    package var pageSetupRelationshipId: String?
    /// The cell notes as the file had them. The writer compares the sheet's notes against this: unchanged, the
    /// source `comments` and VML parts are re-packed byte for byte; changed, both are regenerated.
    package var comments: [CellRef: CellNote] = [:]
    /// The threaded comments as the file had them (B.80), under the same rule as `comments`.
    package var threads: [CellRef: CommentThread] = [:]
    /// The pictures, charts and shapes as the file's drawing had them (B.72, B.75). While `Sheet.images` / `Sheet.charts` / `Sheet.shapes` still
    /// begin with these, the drawing and its parts are re-packed byte for byte (additions are spliced in); once one
    /// of them is changed or removed, the drawing is regenerated from the model.
    package var images: [SheetImage] = []
    package var charts: [Chart] = []
    package var shapes: [Shape] = []
    /// The sparkline groups as the file's extension list had them (B.79): while `Sheet.sparklines` equals this,
    /// the extension travels as bytes; otherwise it is regenerated from the model.
    package var sparklines: [SparklineGroup] = []
    /// `x14:cfRule` elements of the source's extension that no modelled rule claimed (B.82): dropped, out loud,
    /// when the conditional formats are regenerated.
    package var unmatchedConditionalExtensions = 0
    /// The drawing part, the parts it referenced, and what it held that the model could not (shapes, …).
    package var drawingPath: String?
    package var drawingParts: [String] = []
    package var drawingUnmodelled: [String] = []
    /// Set when the sheet's part is not a `<worksheet>` — a chart sheet, a dialog sheet, a macro sheet. See
    /// `ForeignSheet`.
    package var foreignSheet: ForeignSheet?
    /// True when the sheet is a worksheet that was left unread by `ReadOptions.sheets`: its part is carried in
    /// `foreignSheet` as the bytes it arrived in, and it has no cells here because nobody looked, not because it
    /// is empty (spec Appendix B.39.10).
    package var isUnread = false
    package init() {}
    package var isEmpty: Bool { fragments.isEmpty && relationships.isEmpty && foreignSheet == nil }
}

/// A sheet the workbook declares that is not a worksheet: SpreadsheetML also has chart sheets, dialog sheets and
/// macro sheets, and a workbook may mix them with ordinary ones. None of them is a grid, so the model has no
/// vocabulary for what they hold — but they are still sheets, in the sheet order, with a name a formula may use.
///
/// So they are carried rather than interpreted: the part arrives as bytes and leaves as the same bytes, keeping
/// the content type and the relationship type the package gave it. Reading one is reported (`degraded`), because
/// a caller iterating `Workbook.sheets` finds a sheet with no cells, and without the warning that reads as
/// "the sheet was empty" rather than "this sheet is not a grid" (spec Appendix B.35).
package struct ForeignSheet: Sendable, Hashable {
    /// The root element of the part — "chartsheet", "dialogsheet", "macrosheet".
    package var root: String
    /// The relationship type the workbook part used to point at it.
    package var relationshipType: String
    /// The content type `[Content_Types].xml` gave the part.
    package var contentType: String
    /// The part exactly as it arrived.
    package var body: Data

    package init(root: String, relationshipType: String, contentType: String, body: Data) {
        self.root = root; self.relationshipType = relationshipType; self.contentType = contentType; self.body = body
    }

    /// What to call it in a message: "a chart sheet", "a dialog sheet".
    package var description: String {
        switch root {
        case "worksheet": return "an unread worksheet"
        case "chartsheet": return "a chart sheet"
        case "dialogsheet": return "a dialog sheet"
        case "macrosheet": return "a macro sheet"
        default: return "a <\(root)> sheet"
        }
    }
}
