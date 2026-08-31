import Foundation

/// Everything a reader saw but did not interpret, kept so that writing the same format back loses nothing (fidelity
/// level F3, spec §6): charts, drawings, pivot caches, VBA, custom XML, themes — as bytes, with their relationships
/// and content types. Converting to another format cannot carry these; the writer lists them as `dropped` warnings.
public struct PreservationStore: Sendable, Hashable {
    public var sourceFormat: SheetFormat?
    /// Uninterpreted parts by package path ("xl/charts/chart1.xml", "xl/vbaProject.bin"), bytes untouched.
    public var opaqueParts: [String: Data] = [:]
    /// `[Content_Types].xml` entries of the source: extension defaults and part overrides, so opaque parts keep
    /// their declarations when re-packed.
    public var contentTypeDefaults: [String: String] = [:]
    public var contentTypeOverrides: [String: String] = [:]
    /// Relationships of interpreted parts that point at opaque parts, keyed by the source part's path. Their ids
    /// are immutable: new relationships are numbered from the highest existing id + 1.
    public var relationships: [String: [Relationship]] = [:]
    /// Unknown children of `<workbook>` in document order (`extLst`, `pivotCaches`, `externalReferences`, …).
    public var workbookFragments: [XMLFragment] = []
    /// Attributes of the `<workbook>` root element (namespace declarations, `mc:Ignorable`) — needed so fragments
    /// that use those prefixes stay well-formed.
    public var workbookRootAttributes: [String: String] = [:]
    /// Attributes of `<workbookPr>` other than the ones the model owns.
    public var workbookPrAttributes: [String: String] = [:]
    /// Parts of styles.xml that index-reference each other and must be re-emitted verbatim (`tableStyles`,
    /// `cellStyles`, `cellStyleXfs`, `extLst`), plus the source style tables in their original order.
    public var styleFragments: [XMLFragment] = []
    public var styleTables: StyleTables?
    /// The generating application's declared name / version (docProps/app.xml), informational.
    public var application: String?

    public init() {}

    public var isEmpty: Bool { opaqueParts.isEmpty && workbookFragments.isEmpty && styleFragments.isEmpty }

    /// Whether a VBA project rides along among the preserved parts.
    ///
    /// Only a macro-enabled workbook can hold one, so every other target has to report it as `.macros` rather than
    /// fold it into a count of "parts": the subject is what decides which format `WriteResult.suggest` names, and a
    /// macro loss answered with "write XLSX instead" points at a format that loses them too (spec Appendix B.22).
    public var hasVBAProject: Bool { opaqueParts.keys.contains { $0.hasSuffix("vbaProject.bin") } }

    /// Human-readable inventory: "VBA project: yes / charts: 2 / drawings: 1 / other parts: 3".
    public var summary: String {
        var counts: [(String, Int)] = []
        func count(_ label: String, _ predicate: (String) -> Bool) {
            let n = opaqueParts.keys.filter(predicate).count
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
        let other = opaqueParts.count - known
        var parts = ["VBA project: \(vba ? "yes" : "no")"] + counts.map { "\($0.0): \($0.1)" }
        if other > 0 { parts.append("other parts: \(other)") }
        return parts.joined(separator: " / ")
    }
}

/// A raw XML element kept as text (the element's qualified name and its complete serialization).
public struct XMLFragment: Sendable, Hashable {
    public var element: String
    public var xml: String
    public init(element: String, xml: String) { self.element = element; self.xml = xml }
}

/// An OPC relationship (`<Relationship Id Type Target TargetMode>`).
public struct Relationship: Sendable, Hashable {
    public var id: String
    public var type: String
    public var target: String
    public var targetMode: String?
    public init(id: String, type: String, target: String, targetMode: String? = nil) {
        self.id = id; self.type = type; self.target = target; self.targetMode = targetMode
    }
    /// The numeric part of "rId12" (nil for other id shapes).
    public var number: Int? { id.hasPrefix("rId") ? Int(id.dropFirst(3)) : nil }
}

/// The style tables of a source styles.xml in their original order, so indices referenced by preserved fragments
/// (`cellStyleXfs`, `dxfs` via `tableStyles`) and by `<col style>` stay valid after a rewrite.
public struct StyleTables: Sendable, Hashable {
    public var fonts: [Font] = []
    public var fills: [Fill] = []
    public var borders: [Border] = []
    /// Custom number formats by id (ids ≥ 164).
    public var numberFormats: [Int: String] = [:]
    /// Raw `<font>` / `<fill>` / `<border>` elements, re-emitted verbatim in place of the parsed forms so attributes the
    /// model does not carry (gradient fills, condense/extend) survive.
    public var fontXML: [String] = []
    public var fillXML: [String] = []
    public var borderXML: [String] = []
    /// Attributes of the `<styleSheet>` root (namespace declarations used by preserved sections).
    public var rootAttributes: [String: String] = [:]
    /// `cellStyleXfs`, entry by entry: the raw `<xf>` and its parsed form. Named styles point into this table by
    /// index, so entries no `cellStyle` names have to be kept anyway — dropping one renumbers every entry after it.
    public var cellStyleXfXML: [String] = []
    public var cellStyleXfs: [CellStyle] = []
    /// Named style name → its index in `cellStyleXfs`, as the source file had it. Names the file already knew keep
    /// their index on a write-back; new ones are appended.
    public var namedStyleXfIndex: [String: Int] = [:]
    /// The differential formats (`<dxfs>`), parsed and raw. Conditional formats, tables and colour filters address
    /// them by index, so the source entries keep their positions and new ones are appended after them.
    public var dxfs: [DifferentialStyle] = []
    public var dxfXML: [String] = []
    public init() {}
}

/// Per-sheet preserved material (travels with the sheet so renames and moves keep it).
public struct SheetPreservation: Sendable, Hashable {
    /// The source part path ("xl/worksheets/sheet1.xml"), reused on write so opaque parts that name it stay valid.
    public var partPath: String?
    /// The workbook relationship id and `sheetId` the sheet had in the source.
    public var relationshipId: String?
    public var sheetId: Int?
    /// Unknown children of `<worksheet>` in document order (conditional formatting, data validation, drawings, tables, …).
    public var fragments: [XMLFragment] = []
    /// Relationships of the sheet part other than hyperlinks (drawing, comments, table, printerSettings, …).
    public var relationships: [Relationship] = []
    /// Attributes of the `<worksheet>` root element (namespace declarations, `mc:Ignorable`).
    public var rootAttributes: [String: String] = [:]
    /// `<pageSetup r:id>` — the printer-settings part the sheet was configured against. The part itself is opaque
    /// and its relationship is in `relationships`; without this attribute the link between them is lost.
    public var pageSetupRelationshipId: String?
    /// The cell notes as the file had them. The writer compares the sheet's notes against this: unchanged, the
    /// source `comments` and VML parts are re-packed byte for byte; changed, both are regenerated.
    public var comments: [CellRef: CellNote] = [:]
    /// Set when the sheet's part is not a `<worksheet>` — a chart sheet, a dialog sheet, a macro sheet. See
    /// `ForeignSheet`.
    public var foreignSheet: ForeignSheet?
    public init() {}
    public var isEmpty: Bool { fragments.isEmpty && relationships.isEmpty && foreignSheet == nil }
}

/// A sheet the workbook declares that is not a worksheet: SpreadsheetML also has chart sheets, dialog sheets and
/// macro sheets, and a workbook may mix them with ordinary ones. None of them is a grid, so the model has no
/// vocabulary for what they hold — but they are still sheets, in the sheet order, with a name a formula may use.
///
/// So they are carried rather than interpreted: the part arrives as bytes and leaves as the same bytes, keeping
/// the content type and the relationship type the package gave it. Reading one is reported (`degraded`), because
/// a caller iterating `Workbook.sheets` finds a sheet with no cells, and without the warning that reads as
/// "the sheet was empty" rather than "this sheet is not a grid" (spec Appendix B.35).
public struct ForeignSheet: Sendable, Hashable {
    /// The root element of the part — "chartsheet", "dialogsheet", "macrosheet".
    public var root: String
    /// The relationship type the workbook part used to point at it.
    public var relationshipType: String
    /// The content type `[Content_Types].xml` gave the part.
    public var contentType: String
    /// The part exactly as it arrived.
    public var body: Data

    public init(root: String, relationshipType: String, contentType: String, body: Data) {
        self.root = root; self.relationshipType = relationshipType; self.contentType = contentType; self.body = body
    }

    /// What to call it in a message: "a chart sheet", "a dialog sheet".
    public var description: String {
        switch root {
        case "chartsheet": return "a chart sheet"
        case "dialogsheet": return "a dialog sheet"
        case "macrosheet": return "a macro sheet"
        default: return "a <\(root)> sheet"
        }
    }
}
