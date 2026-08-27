import Foundation

/// Failures of reading, writing and of operations the model cannot perform as asked. "Could not do it" is an
/// error; "wrote it, but something degraded" is a `ConversionWarning` on the `WriteResult` instead — nothing is
/// lost silently.
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
    /// An operation named a sheet the workbook does not have (`Workbook.editSheet(named:_:)`). Lookups answer
    /// with an Optional (`wb.sheets["X"]`); an operation that would otherwise do nothing in silence throws this.
    case sheetNotFound(name: String)
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
        case .sheetNotFound(let n): "no sheet named \(n)"
        case .ioFailure(let d): "input/output failure: \(d)"
        }
    }

    /// What `error.localizedDescription` shows. Without this, Foundation falls back to "The operation couldn’t be
    /// completed. (SheetCore.SheetError error 0.)", which tells nobody anything.
    public var errorDescription: String? { description }
}
