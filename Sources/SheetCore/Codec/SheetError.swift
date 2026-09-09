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
    /// A file this library recognises and will not open: an encrypted package, or the legacy `.xls` generation.
    /// The same value `SheetFormat.probe` answers with, thrown rather than returned (spec Appendix B.52).
    case unopenable(UnopenableInput)
    /// The `CodecSet` asked to read or write has no codec for the format. The message names the product to link
    /// and the format to name in the set; `SheetFormat.productName` is the same product name as a value.
    case noCodec(for: SheetFormat)
    /// Password protection this library does not handle — reading (ODF 1.1's Blowfish, Excel 2007's "standard"
    /// encryption, a hash or key size outside the supported set) and writing (a CSV file is plain text by
    /// definition; Numbers' encryption is not documented). Distinct from `wrongPassword`: asking again cannot help.
    case unsupportedEncryption(detail: String)
    /// A limit of the format or the environment — a second sheet in delimited text, a Numbers table beyond its
    /// row and column caps, text a chosen encoding cannot carry, a row-by-row write on WASI.
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
    /// The file is password-protected and the password given does not open it (spec Appendix B.39.9).
    case wrongPassword

    public var description: String {
        switch self {
        case .unrecognizedFormat: "unrecognized format"
        case .corruptedContainer(let d): "corrupted container: \(d)"
        case .malformedPart(let p, let d): "malformed part \(p): \(d)"
        case .unopenable(let input): input.reason
        case .noCodec(let format): Self.noCodecMessage(format)
        case .unsupportedEncryption(let d): "unsupported protection: \(d)"
        case .unsupportedFeature(let s): "unsupported: \(s)"
        case .unsupportedVersion(let f, let r): "unsupported version \(f) (supported: \(r.lowerBound)…\(r.upperBound))"
        case .formulaSyntax(let o, let d): "formula syntax error at \(o): \(d)"
        case .invalidWorkbook(let s): "invalid workbook: \(s)"
        case .sheetNotFound(let n): "no sheet named \(n)"
        case .ioFailure(let d): "input/output failure: \(d)"
        case .wrongPassword: "the password does not open this file"
        }
    }

    /// The refusal a `CodecSet` gives for a format it has no codec for — the message `noCodec(for:)` carries, and
    /// what the set itself throws (spec Appendix B.52; the wording is B.44's, unchanged).
    static func noCodecMessage(_ format: SheetFormat) -> String {
        "no codec for .\(format.rawValue) is in this CodecSet — link the \(format.productName) product and name .\(format.rawValue) in the set, or use the SwiftSheets product's CodecSet.all, which has every codec"
    }

    /// What `error.localizedDescription` shows. Without this, Foundation falls back to "The operation couldn’t be
    /// completed. (SheetCore.SheetError error 0.)", which tells nobody anything.
    public var errorDescription: String? { description }
}
