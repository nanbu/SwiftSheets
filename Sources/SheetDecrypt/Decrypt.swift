import Foundation
@_exported import SwiftSheets

// SheetDecrypt — opening password-protected files (spec Appendix B.39.9, Rev 4.29).
//
// The plain products recognise a protected file and refuse it by name; this product is what opens one. It holds
// AES's inverse cipher, the key derivation, the compound file's reader and the two package forms — and nothing
// that encrypts, so that an app linking it can say "decryption only". Everything below is one function,
// `decrypt`, and thin conveniences that call it and then the plain API.

/// The plain package inside a protected file: an OOXML package under Excel's agile encryption (a compound file),
/// or an ODF package whose entries are encrypted one by one (ODF 1.2 / 1.3 §4.3). Which it is comes from the
/// bytes, the same way `SheetFormat.probe` tells them apart.
///
/// Data that is not protected comes back as it is, so a caller who does not know whether a file is protected can
/// pass every file through with the password it has — what `ReadOptions.password` did before 0.17.0. Whether a
/// file is protected is `SheetFormat.probe`'s question. A wrong password throws `SheetError.wrongPassword`; a
/// form this library does not open (Excel 2007's "standard" encryption, ODF 1.1's Blowfish, a password-protected
/// Numbers document) throws `unsupportedFeature` naming it. `limits` is what the container may declare about
/// itself before it is refused (`ReadOptions.limits`).
public func decrypt(_ data: Data, password: String, limits: ZipLimits = ZipLimits()) throws -> Data {
    // a compound file: Excel's protected package, or a legacy .xls — the probe says which
    if let unopenable = UnopenableInput.probe(data) {
        guard unopenable == .encryptedOOXML else { throw unopenable.error }
        return try OOXMLEncryption.decrypt(data, password: password)
    }
    switch SheetFormat.detect(from: data) {
    case .ods:
        // an encrypted ODF package keeps `mimetype` in the clear; the manifest names the encrypted entries
        let zip = try ZipArchive(data: data, limits: limits)
        guard zip.contains("META-INF/manifest.xml") else { return data }
        // a manifest that will not parse names no encrypted entry, and the package goes on as plain — the plain
        // readers treat it the same way
        let manifest = ManifestParser()
        try? manifest.run(try zip.read("META-INF/manifest.xml"), part: "META-INF/manifest.xml")
        let entries = manifest.encryptedEntries
        guard !entries.isEmpty else { return data }
        return try ODSEncryption.decrypt(zip, entries: entries, password: password)
    case .numbers:
        // refused by name rather than handed back as if it were plain
        if let unopenable = UnopenableInput.probe(in: try ZipInspection(data: data)) { throw unopenable.error }
        return data
    default:
        return data
    }
}

/// `decrypt` over a file, mapped rather than copied (`Data(contentsOf:options: .mappedIfSafe)`, as the facade reads).
public func decrypt(contentsOf url: URL, password: String, limits: ZipLimits = ZipLimits()) throws -> Data {
    try decrypt(try Data(contentsOf: url, options: .mappedIfSafe), password: password, limits: limits)
}

extension Workbook {
    /// Opens a file with its password: `decrypt`, then `Workbook(contentsOf:options:)` over the plain package.
    public init(contentsOf url: URL, password: String, options: ReadOptions = ReadOptions()) throws {
        self = try Workbook.read(contentsOf: url, password: password, options: options).workbook
    }

    /// Parses protected bytes: `decrypt`, then `Workbook(data:format:options:)` over the plain package.
    public init(data: Data, password: String, format: SheetFormat? = nil, options: ReadOptions = ReadOptions()) throws {
        self = try Workbook.read(data, password: password, format: format, options: options).workbook
    }

    /// `Workbook.read(contentsOf:options:)` with a password: the file is decrypted whole, then read as the plain
    /// package it holds. The warnings are the plain read's.
    public static func read(contentsOf url: URL, password: String, options: ReadOptions = ReadOptions()) throws -> ReadResult {
        // a Numbers document saved as a package is a folder: nothing to decrypt, and the plain facade opens it
        if url.isDirectoryOnDisk { return try read(contentsOf: url, options: options) }
        var opts = options
        if opts.filename == nil { opts.filename = url.lastPathComponent }
        return try read(try decrypt(contentsOf: url, password: password, limits: options.limits), format: nil, options: opts)
    }

    /// `Workbook.read(_:format:options:)` with a password.
    public static func read(_ data: Data, password: String, format: SheetFormat? = nil, options: ReadOptions = ReadOptions()) throws -> ReadResult {
        try read(try decrypt(data, password: password, limits: options.limits), format: format, options: options)
    }

    /// `Workbook.inspect(contentsOf:options:)` with a password. A protected package has to be decrypted whole
    /// before its directory can be read, so this costs what a read costs, not what an inspection does.
    public static func inspect(contentsOf url: URL, password: String, options: InspectOptions = InspectOptions()) throws -> WorkbookSummary {
        if url.isDirectoryOnDisk { return try inspect(contentsOf: url, options: options) }
        var opts = options
        if opts.filename == nil { opts.filename = url.lastPathComponent }
        return try inspect(try decrypt(contentsOf: url, password: password, limits: options.limits), format: nil, options: opts)
    }

    /// `Workbook.inspect(_:format:options:)` with a password.
    public static func inspect(_ data: Data, password: String, format: SheetFormat? = nil, options: InspectOptions = InspectOptions()) throws -> WorkbookSummary {
        try inspect(try decrypt(data, password: password, limits: options.limits), format: format, options: options)
    }
}

extension StreamingReader {
    /// `StreamingReader(contentsOf:limits:csv:)` with a password. The package is decrypted whole first — neither a
    /// compound file nor an encrypted ODF entry can be walked a row at a time — and then walked as the plain
    /// package it holds, so a protected file costs its decrypted size in memory where a plain one is mapped.
    public init(contentsOf url: URL, password: String, limits: ZipLimits = ZipLimits(), csv: CSVReadOptions = CSVReadOptions()) throws {
        if url.isDirectoryOnDisk { try self.init(contentsOf: url, limits: limits, csv: csv); return }
        try self.init(data: try decrypt(contentsOf: url, password: password, limits: limits), format: nil, limits: limits, csv: csv,
                      filename: url.lastPathComponent)
    }

    /// `StreamingReader(data:format:limits:csv:filename:)` with a password.
    public init(data: Data, password: String, format: SheetFormat? = nil, limits: ZipLimits = ZipLimits(),
                csv: CSVReadOptions = CSVReadOptions(), filename: String? = nil) throws {
        try self.init(data: try decrypt(data, password: password, limits: limits), format: format, limits: limits, csv: csv, filename: filename)
    }
}
