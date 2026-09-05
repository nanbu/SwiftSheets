import Foundation
@_exported import SheetDecrypt

// SheetEncrypt — protecting files with a password (spec Appendix B.39.9, Rev 4.29).
//
// Depends on SheetDecrypt (the key schedule, the key derivation, the parameters) and adds the cipher's forward
// direction, the random salts and the compound file's writer. An app that links this product carries both
// halves; one that links SheetDecrypt alone carries no encryption code. Everything below is one function,
// `encrypt`, and thin conveniences that write the plain package first and then call it.

/// `plain` — a package this library wrote, or any plain XLSX / XLSM / ODS — protected with `password` the way its
/// format protects files: XLSX / XLSM as Excel's agile encryption (AES-256, SHA-512, a hundred thousand rounds —
/// what Excel 2010 and later write), ODS as ODF 1.3 §4.3 package encryption (AES-CBC, PBKDF2 — what LibreOffice
/// writes). CSV has no protected form (it is plain text by definition) and Numbers' is not documented; both throw
/// `unsupportedFeature` saying so. What comes back opens with `SheetDecrypt.decrypt` and with the format's own
/// applications.
public func encrypt(_ plain: Data, as format: SheetFormat, password: String) throws -> Data {
    switch format {
    case .xlsx, .xlsm: return try OOXMLEncryption.encrypt(plain, password: password)
    case .ods: return try ODSEncryption.encrypt(plain, password: password)
    case .csv: throw SheetError.unsupportedFeature("a CSV file cannot be password-protected: it is plain text by definition")
    case .numbers: throw SheetError.unsupportedFeature("a password-protected Numbers document cannot be written: Numbers' encryption is not documented")
    }
}

extension Workbook {
    /// `write(as:options:)`, then `encrypt` over the bytes. The warnings and the suggestion are the plain write's.
    public func write(as format: SheetFormat, options: WriteOptions = WriteOptions(), password: String) throws -> WriteResult {
        let plain = try write(as: format, options: options)
        return WriteResult(data: try encrypt(plain.data, as: format, password: password), warnings: plain.warnings, suggestion: plain.suggestion)
    }

    /// The protected bytes only, when warnings are not of interest.
    public func data(as format: SheetFormat, options: WriteOptions = WriteOptions(), password: String) throws -> Data {
        try write(as: format, options: options, password: password).data
    }

    /// `write(to:as:options:)` with a password. The format is chosen the way the plain write chooses it (the
    /// argument, else the extension, else the source format, else .xlsx), and the write is atomic like it.
    @discardableResult
    public func write(to url: URL, as format: SheetFormat? = nil, options: WriteOptions = WriteOptions(), password: String) throws -> WriteResult {
        let result = try write(as: outputFormat(for: url, requested: format), options: options, password: password)
        try result.data.write(to: url, options: .atomic)
        return result
    }
}
