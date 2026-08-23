import Foundation

/// Failures of reading and writing. "Could not read / write" is an error; "wrote it, but something degraded" is a
/// `ConversionWarning` on the `WriteResult` instead — nothing is lost silently.
public enum SheetError: Error, Sendable, CustomStringConvertible, LocalizedError, Equatable {
    case unrecognizedFormat
    /// The ZIP (or other container) layer failed.
    case corruptedContainer(detail: String)
    /// A part exists but cannot be parsed. `path` is the part (or, for CSV, the byte offset) that failed.
    case malformedPart(path: String, detail: String)
    /// Encrypted files, formats not implemented yet, …
    case unsupportedFeature(String)
    /// A Numbers file newer than the supported range.
    case unsupportedVersion(found: String, supported: ClosedRange<Int>)
    case formulaSyntax(offset: Int, detail: String)
    /// The model cannot be written as asked (e.g. a workbook with no sheets).
    case invalidWorkbook(String)
    /// Reading or writing the file itself failed (the streaming writer's only failure mode of its own).
    case ioFailure(detail: String)

    public var description: String {
        switch self {
        case .unrecognizedFormat: "unrecognized format"
        case .corruptedContainer(let d): "corrupted container: \(d)"
        case .malformedPart(let p, let d): "malformed part \(p): \(d)"
        case .unsupportedFeature(let s): "unsupported: \(s)"
        case .unsupportedVersion(let f, let r): "unsupported version \(f) (supported: \(r.lowerBound)…\(r.upperBound))"
        case .formulaSyntax(let o, let d): "formula syntax error at \(o): \(d)"
        case .invalidWorkbook(let s): "invalid workbook: \(s)"
        case .ioFailure(let d): "input/output failure: \(d)"
        }
    }

    /// What `error.localizedDescription` shows. Without this, Foundation falls back to "The operation couldn’t be
    /// completed. (SheetCore.SheetError error 0.)", which tells nobody anything.
    public var errorDescription: String? { description }
}
