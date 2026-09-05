import Foundation
import SheetCore
import SheetODS

/// Password protection of an OpenDocument package as ODF 1.2 §3.4 / 1.3 §4.3 define it: every entry but
/// `mimetype` and the manifest is deflated, padded, and AES-CBC-encrypted under a key derived from the password
/// (a SHA-256 start key through PBKDF2-HMAC-SHA1), with the salt, the vector and a checksum of the compressed
/// bytes recorded in the manifest beside the entry (spec Appendix B.39.9). Reading takes what the manifest
/// says (SHA-1 or SHA-256 start keys and checksums, AES of any size); writing — the SheetEncrypt product's
/// extension — uses what LibreOffice uses. The Blowfish form of ODF 1.0 / 1.1 is recognised and refused by name.
/// The manifest itself is read by SheetODS (`ManifestParser`), which hands over what it says about each entry.
package enum ODSEncryption {
    static let aesAlgorithms = ["http://www.w3.org/2001/04/xmlenc#aes256-cbc", "http://www.w3.org/2001/04/xmlenc#aes192-cbc", "http://www.w3.org/2001/04/xmlenc#aes128-cbc"]

    /// The package with every encrypted entry replaced by its plain bytes — the input the ordinary reader takes.
    package static func decrypt(_ zip: ZipArchive, entries: [String: ODSEncryptedEntry], password: String) throws -> Data {
        let out = ZipWriter()
        for name in zip.names where !name.hasSuffix("/") {
            let bytes = try zip.read(name)
            if name == "META-INF/manifest.xml" {
                // the manifest of the plain package says nothing about encryption any more
                out.add(name, Data(stripEncryption(String(decoding: bytes, as: UTF8.self)).utf8))
                continue
            }
            guard let enc = entries[name] else { out.add(name, bytes, stored: name == "mimetype"); continue }
            out.add(name, try decryptEntry(bytes, enc, password: password))
        }
        return out.finish()
    }

    /// The manifest without its `encryption-data` elements.
    static func stripEncryption(_ manifest: String) -> String {
        var out = ""
        var rest = Substring(manifest)
        while let start = rest.range(of: "<manifest:encryption-data") {
            out += rest[..<start.lowerBound]
            if let end = rest[start.upperBound...].range(of: "</manifest:encryption-data>") {
                rest = rest[end.upperBound...]
            } else if let close = rest[start.upperBound...].range(of: "/>") {
                rest = rest[close.upperBound...]
            } else {
                return out + rest[start.lowerBound...]
            }
        }
        return out + rest
    }

    static func decryptEntry(_ cipher: Data, _ enc: ODSEncryptedEntry, password: String) throws -> Data {
        guard let algorithm = enc.algorithm else { throw SheetError.corruptedContainer(detail: "an encrypted entry names no algorithm") }
        guard aesAlgorithms.contains(algorithm) else {
            throw SheetError.unsupportedFeature("the ODF entry is encrypted with \(algorithm); only AES-CBC (ODF 1.2 and later) is supported — the Blowfish form of ODF 1.1 is not")
        }
        guard enc.keyDerivation == nil || enc.keyDerivation == "PBKDF2" else { throw SheetError.unsupportedFeature("the ODF key derivation \(enc.keyDerivation!) is not supported (only PBKDF2 is)") }
        guard let salt = enc.salt, let iv = enc.iv, let size = enc.size else { throw SheetError.corruptedContainer(detail: "an encrypted entry lacks its salt, vector or size") }
        let iterations = enc.iterations ?? 1024
        guard iterations > 0, iterations <= 10_000_000 else { throw SheetError.corruptedContainer(detail: "an encrypted entry asks for \(iterations) rounds") }
        let keySize = enc.keySize ?? (algorithm.contains("aes256") ? 32 : algorithm.contains("aes192") ? 24 : 16)
        // the start key: the password hashed, SHA-256 unless the manifest says SHA-1 (ODF 1.1's default)
        let startKey: Data
        if let name = enc.startKeyGeneration {
            if name.hasSuffix("#sha256") { startKey = SHA256.hash(Data(password.utf8)) }
            else if name.hasSuffix("#sha1") { startKey = SHA1.hash(Data(password.utf8)) }
            else { throw SheetError.unsupportedFeature("the ODF start-key generation \(name) is not supported") }
        } else {
            startKey = SHA1.hash(Data(password.utf8))
        }
        let key = PBKDF2<SHA1>.derive(password: startKey.prefix(enc.startKeySize ?? startKey.count), salt: salt, iterations: iterations, length: keySize)
        guard cipher.count % 16 == 0, !cipher.isEmpty else { throw SheetError.corruptedContainer(detail: "an encrypted entry is not whole blocks") }
        var plain = try AES(key: key).decryptCBC(cipher, iv: iv)
        // W3C padding: the last byte says how many padding bytes there are
        if let last = plain.last, last >= 1, last <= 16, plain.count >= Int(last) { plain = plain.prefix(plain.count - Int(last)) }
        // the checksum is over the first 1024 bytes of the compressed bytes — the first thing that tells a wrong
        // password from a right one
        if let checksum = enc.checksum, let type = enc.checksumType {
            let window = plain.prefix(1024)
            let computed: Data
            if type.hasSuffix("#sha256-1k") { computed = SHA256.hash(window) }
            else if type.hasSuffix("#sha1-1k") || type == "SHA1/1K" { computed = SHA1.hash(window) }
            else { throw SheetError.unsupportedFeature("the ODF checksum type \(type) is not supported") }
            guard computed == checksum else { throw SheetError.wrongPassword }
        }
        do {
            return try Deflate.decompress(plain, expectedSize: size)
        } catch {
            throw SheetError.wrongPassword   // without a checksum, a wrong key shows up here as noise that will not inflate
        }
    }
}
