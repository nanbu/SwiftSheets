import Foundation

/// A container the plain products recognise but will not open, and why. Spec §1.3 puts decryption outside the
/// plain products (the SheetDecrypt product opens a protected file; nothing here or in the codecs contains a
/// cipher) and the legacy `.xls` (BIFF) format outside the library; §14.11 asks that both fail *explicitly*
/// rather than looking like corruption. Detection is content-based and reads only public specifications: the compound-file signature of
/// [MS-CFB], the `EncryptedPackage` stream of [MS-OFFCRYPTO] (ECMA-376 Part 2 agile / standard encryption), and
/// `manifest:encryption-data` of ODF 1.3 §4.3.
public enum UnopenableInput: Sendable, Hashable {
    /// An OLE compound file carrying an `EncryptedPackage` stream — a password-protected .xlsx / .xlsm.
    case encryptedOOXML
    /// An OLE compound file that is not an encrypted package: a .xls / .doc / .ppt of the 1997–2003 generation.
    case legacyCompoundFile
    /// An ODF package whose manifest says its entries are encrypted.
    case encryptedODF
    /// A Numbers document saved with a password: its package carries an `.iwph` header and nothing readable.
    case encryptedNumbers

    /// The eight bytes every OLE compound file starts with ([MS-CFB] §2.2).
    package static let compoundFileSignature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    /// What the bytes are, when they are one of these. Nil for everything else — including well-formed
    /// spreadsheets, which is why this is only consulted once ordinary detection has come up empty.
    public static func probe(_ data: Data) -> UnopenableInput? {
        guard data.count >= 8, [UInt8](data.prefix(8)) == compoundFileSignature else { return nil }
        // Directory entry names in a compound file are UTF-16LE, so the stream name appears literally in the
        // bytes. Reading the FAT to find the directory would be a decoder for a format we do not support — and the
        // directory is not near the front: Office and this library write it after the streams, so it lies past
        // the package itself. The whole file is scanned (Appendix B.39.9, Rev 4.29; a mebibyte window used to
        // call every protected file over a megabyte a legacy .xls).
        return containsUTF16LE("EncryptedPackage", in: data) ? .encryptedOOXML : .legacyCompoundFile
    }

    /// What an already-open package is, when its manifest declares encryption (ODF 1.3 §4.3: the `mimetype` entry
    /// stays in the clear, so such a file still detects as `.ods`).
    public static func probe(in container: ZipInspection) -> UnopenableInput? {
        if container.contains(".iwph") { return .encryptedNumbers }
        guard let manifest = container.entry(named: "META-INF/manifest.xml") else { return nil }
        return String(decoding: manifest, as: UTF8.self).contains("encryption-data") ? .encryptedODF : nil
    }

    /// The error to throw. `unsupportedFeature` is the case spec §4.3 reserves for "encrypted files, formats not
    /// implemented yet".
    public var error: SheetError { .unsupportedFeature(reason) }

    var reason: String {
        switch self {
        case .encryptedOOXML:
            "the OOXML package is encrypted (ECMA-376 Part 2 / MS-OFFCRYPTO); the plain products carry no cipher — decrypt it with the SheetDecrypt product first (SheetDecrypt.decrypt, or Workbook(contentsOf:password:))"
        case .legacyCompoundFile:
            "an OLE compound file: the legacy .xls (BIFF) generation is out of scope — save it as .xlsx first"
        case .encryptedODF:
            "the ODF package is encrypted (ODF 1.3 §4.3); the plain products carry no cipher — decrypt it with the SheetDecrypt product first (SheetDecrypt.decrypt, or Workbook(contentsOf:password:))"
        case .encryptedNumbers:
            "the Numbers document is password-protected (an .iwph package); SwiftSheets does not decrypt Numbers documents — remove the password in Numbers first"
        }
    }
}

extension UnopenableInput {
    /// What a compound file is, read from a source a window at a time — `SheetFormat.probe(contentsOf:)`'s way,
    /// which never holds a whole file. The caller has already matched the signature.
    package static func probe(compoundFile source: any ByteSource) throws -> UnopenableInput {
        try containsUTF16LE("EncryptedPackage", in: source) ? .encryptedOOXML : .legacyCompoundFile
    }

    /// True when the ASCII `needle`, encoded as UTF-16LE, occurs anywhere in `data` — the same scan as below.
    static func containsUTF16LE(_ needle: String, in data: Data) -> Bool {
        (try? containsUTF16LE(needle, in: DataByteSource(data))) ?? false
    }

    /// True when the ASCII `needle`, encoded as UTF-16LE, occurs anywhere in `source`: a linear scan in windows of a
    /// mebibyte that overlap by a pattern's length, so a name across a window's edge is still seen. Only ever run
    /// on a compound file, which ordinary detection has already failed to open, and cheap beside decrypting one.
    static func containsUTF16LE(_ needle: String, in source: any ByteSource) throws -> Bool {
        var pattern = [UInt8]()
        for scalar in needle.unicodeScalars { pattern.append(UInt8(scalar.value & 0xFF)); pattern.append(UInt8(scalar.value >> 8)) }
        let window = 1 << 20
        var start = 0
        while start < source.count {
            let end = Swift.min(source.count, start + window)
            let found = try source.withBytes(in: start..<end) { raw -> Bool in
                guard raw.count >= pattern.count else { return false }
                let last = raw.count - pattern.count
                var i = 0
                while i <= last {
                    if raw[i] == pattern[0] {
                        var j = 1
                        while j < pattern.count, raw[i + j] == pattern[j] { j += 1 }
                        if j == pattern.count { return true }
                    }
                    i += 1
                }
                return false
            }
            if found { return true }
            if end == source.count { return false }
            start = end - (pattern.count - 1)
        }
        return false
    }
}
