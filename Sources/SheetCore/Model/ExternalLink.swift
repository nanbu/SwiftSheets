import Foundation

/// A workbook another workbook's formulas refer to (spec Appendix B.78): what `[1]` in `[1]Data!B2` stands for.
/// The values are never resolved — the file's cached values are what the cells hold — and the list is read-only:
/// it comes from the file (OOXML's `externalLinks/` parts; in ODS, the documents the formulas name) and a
/// same-format write carries the parts as they were.
public struct ExternalLink: Hashable, Sendable {
    /// The number formulas use (`[1]`, `[2]`, …) — the link's position in the file's list, from 1.
    public let index: Int
    /// The other workbook as the file names it: a path relative to this file, an absolute path, or a URL.
    public let target: String
    /// The sheet names the file recorded for the other workbook (OOXML caches them; ODS names them only in
    /// the formulas, so here they are the ones the formulas use).
    public let sheetNames: [String]
    public init(index: Int, target: String, sheetNames: [String]) {
        self.index = index; self.target = target; self.sheetNames = sheetNames
    }
}
