/// A read-only snapshot of a workbook's preserved material (spec Appendix B.46).
///
/// This is not a complete inventory or a promise that a target format can keep that material. A zero part
/// count does not mean there are no preserved XML fragments. Reading a summary never expands opaque parts.
public struct PreservationSummary: Sendable {
    /// The format the preserved material came from; nil for a newly created workbook.
    public let sourceFormat: SheetFormat?
    /// The number of opaque package parts. Excludes XML fragments and objects represented by the model.
    public let opaquePartCount: Int
    /// Whether the preserved parts contain a VBA project. Does not parse or run macros.
    public let hasVBAProject: Bool

    /// Constructs a summary value only; it does not change any workbook's preserved material.
    public init(sourceFormat: SheetFormat?, opaquePartCount: Int, hasVBAProject: Bool) {
        self.sourceFormat = sourceFormat
        self.opaquePartCount = opaquePartCount
        self.hasVBAProject = hasVBAProject
    }
}
