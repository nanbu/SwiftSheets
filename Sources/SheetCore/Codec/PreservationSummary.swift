/// A read-only snapshot of a workbook's preserved material (spec Appendix B.46).
///
/// This is not a complete inventory or a promise that a target format can keep that material. A zero part
/// count does not mean there are no preserved XML fragments. Reading a summary never expands opaque parts.
public struct PreservationSummary: Hashable, Sendable {
    /// The format the preserved material came from; nil for a newly created workbook.
    public let sourceFormat: SheetFormat?
    /// The number of opaque package parts. Excludes XML fragments and objects represented by the model.
    public let opaquePartCount: Int
    /// Whether the preserved parts contain a VBA project. Does not parse or run macros.
    public let hasVBAProject: Bool
    /// What the preserved material holds that the model does not represent, by kind (spec Appendix B.77): the
    /// answer to "what will a conversion drop?" before any write is attempted. A part the model read — a chart
    /// in `sheet.charts`, the theme, a note — is not listed even though its bytes travel; a chart of a kind the
    /// writers cannot draw is, under `.chart`, only once it has been changed. Kinds with a count of zero are absent.
    public let parts: [PreservedPartKind: Int]

    /// Constructs a summary value only; it does not change any workbook's preserved material.
    public init(sourceFormat: SheetFormat?, opaquePartCount: Int, hasVBAProject: Bool, parts: [PreservedPartKind: Int] = [:]) {
        self.sourceFormat = sourceFormat
        self.opaquePartCount = opaquePartCount
        self.hasVBAProject = hasVBAProject
        self.parts = parts
    }
}

/// A kind of preserved material the model does not represent (spec Appendix B.77). A struct with static members
/// rather than an enum, so a kind can be added without breaking a caller's `switch` (B.69); the raw value is a
/// stable name for logs and tests.
public struct PreservedPartKind: Hashable, Sendable, RawRepresentable, CustomStringConvertible, Comparable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// A chart part the model did not read into `sheet.charts` (its drawing could not be read, or it hangs on a chart sheet).
    public static let chart = PreservedPartKind(rawValue: "chart")
    /// A chart sheet or another non-grid sheet, carried whole.
    public static let chartSheet = PreservedPartKind(rawValue: "chartSheet")
    /// A drawing part the model did not read, or a legacy (VML) drawing other than the notes'.
    public static let drawing = PreservedPartKind(rawValue: "drawing")
    /// A group of shapes inside a drawing (kept as bytes until the drawing is rebuilt).
    public static let shapeGroup = PreservedPartKind(rawValue: "shapeGroup")
    /// An object inside a drawing the model has no word for (an ink part, an AlternateContent block, …).
    public static let drawingObject = PreservedPartKind(rawValue: "drawingObject")
    /// A picture part no drawing the model read points at.
    public static let image = PreservedPartKind(rawValue: "image")
    /// A SmartArt diagram (the `dgm:` parts and its frame).
    public static let smartArt = PreservedPartKind(rawValue: "smartArt")
    /// The VBA project of a macro-enabled workbook (a conversion also reports it on its own, as `.macros`).
    public static let vbaProject = PreservedPartKind(rawValue: "vbaProject")
    /// A Basic script library in an ODS package.
    public static let script = PreservedPartKind(rawValue: "script")
    /// A theme part the model did not read.
    public static let theme = PreservedPartKind(rawValue: "theme")
    /// A slicer or a slicer cache.
    public static let slicer = PreservedPartKind(rawValue: "slicer")
    /// A data connection, query table or data model.
    public static let dataConnection = PreservedPartKind(rawValue: "dataConnection")
    /// A custom XML data item (`customXml/item*.xml`).
    public static let customXML = PreservedPartKind(rawValue: "customXML")
    /// An OLE / ActiveX embedding, or an ODS embedded object that is not a chart.
    public static let embeddedObject = PreservedPartKind(rawValue: "embeddedObject")
    /// A link to another workbook (`wb.externalLinks` lists them).
    public static let externalLink = PreservedPartKind(rawValue: "externalLink")
    /// A pivot cache or pivot table the model did not read.
    public static let pivot = PreservedPartKind(rawValue: "pivot")
    /// A named table part the model did not read.
    public static let table = PreservedPartKind(rawValue: "table")
    /// A printer-settings part (the binary settings a printer driver saved for a sheet).
    public static let printerSettings = PreservedPartKind(rawValue: "printerSettings")
    /// A part the model does not read that no other kind names.
    public static let other = PreservedPartKind(rawValue: "other")
    public var description: String { rawValue }
    public static func < (a: PreservedPartKind, b: PreservedPartKind) -> Bool { a.rawValue < b.rawValue }
}
