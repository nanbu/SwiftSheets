import Foundation
import SheetCore

/// Password protection of an OpenDocument package as ODF 1.2 §3.4 / 1.3 §4.3 define it: every entry but
/// `mimetype` and the manifest is deflated, padded, and AES-CBC-encrypted under a key derived from the password
/// (a SHA-256 start key through PBKDF2-HMAC-SHA1), with the salt, the vector and a checksum of the compressed
/// bytes recorded in the manifest beside the entry (spec Appendix B.39.9). Reading takes what the manifest
/// says (SHA-1 or SHA-256 start keys and checksums, AES of any size); writing uses what LibreOffice uses.
/// The Blowfish form of ODF 1.0 / 1.1 is recognised and refused by name.
package enum ODSEncryption {
    struct EntryEncryption {
        var size: Int?
        var checksumType: String?, checksum: Data?
        var algorithm: String?, iv: Data?
        var keyDerivation: String?, keySize: Int?, iterations: Int?, salt: Data?
        var startKeyGeneration: String?, startKeySize: Int?
    }

    static let aesAlgorithms = ["http://www.w3.org/2001/04/xmlenc#aes256-cbc", "http://www.w3.org/2001/04/xmlenc#aes192-cbc", "http://www.w3.org/2001/04/xmlenc#aes128-cbc"]

    /// The package with every encrypted entry replaced by its plain bytes — the input the ordinary reader takes.
    static func decrypt(_ zip: ZipArchive, entries: [String: EntryEncryption], password: String) throws -> Data {
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

    static func decryptEntry(_ cipher: Data, _ enc: EntryEncryption, password: String) throws -> Data {
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

    /// The package with every entry but `mimetype` and the manifest encrypted, and the manifest rewritten to say so.
    package static func encrypt(_ package: Data, password: String) throws -> Data {
        let zip = try ZipArchive(data: package)
        let out = ZipWriter()
        let startKey = SHA256.hash(Data(password.utf8))
        // ODF derives a key per entry, each with its own salt, so the count LibreOffice uses (1,024) is what keeps
        // a document of a dozen entries quick to save and to open; the OOXML form derives one key per file and
        // can afford Excel's hundred thousand
        let iterations = 1024
        var manifestEntries: [String: (size: Int, checksum: Data, iv: Data, salt: Data)] = [:]
        var manifestXML: String?
        for name in zip.names where !name.hasSuffix("/") {
            let bytes = try zip.read(name)
            if name == "mimetype" { out.add(name, bytes, stored: true); continue }
            if name == "META-INF/manifest.xml" { manifestXML = String(decoding: bytes, as: UTF8.self); continue }
            if name.hasPrefix("META-INF/") { out.add(name, bytes); continue }
            // deflate (always a real stream, even for a few bytes), pad, encrypt
            let encoder = try DeflateEncoder()
            var compressed = try encoder.encode(bytes)
            compressed.append(try encoder.finish())
            let checksum = SHA256.hash(compressed.prefix(1024))
            let pad = 16 - compressed.count % 16
            compressed.append(Data(repeating: UInt8(pad), count: pad))
            let salt = RandomBytes.make(16), iv = RandomBytes.make(16)
            let key = PBKDF2<SHA1>.derive(password: startKey, salt: salt, iterations: iterations, length: 32)
            out.add(name, try AES(key: key).encryptCBC(compressed, iv: iv), stored: true)
            manifestEntries[name] = (bytes.count, checksum, iv, salt)
        }
        guard let manifest = manifestXML else { throw SheetError.malformedPart(path: "META-INF/manifest.xml", detail: "the package has no manifest to record the encryption in") }
        out.add("META-INF/manifest.xml", Data(annotate(manifest, with: manifestEntries, iterations: iterations).utf8))
        return out.finish()
    }

    /// The manifest with an `encryption-data` element added to every entry that was encrypted.
    static func annotate(_ manifest: String, with entries: [String: (size: Int, checksum: Data, iv: Data, salt: Data)], iterations: Int) -> String {
        var out = ""
        var rest = Substring(manifest)
        while let start = rest.range(of: "<manifest:file-entry") {
            out += rest[..<start.lowerBound]
            guard let close = rest[start.upperBound...].firstIndex(of: ">") else { out += rest[start.lowerBound...]; return out }
            let tag = rest[start.lowerBound...close]
            var path: String?
            if let r = tag.range(of: "manifest:full-path=\"") {
                let value = tag[r.upperBound...]
                if let q = value.firstIndex(of: "\"") { path = ScannedTag.decodeEntities(String(value[..<q])) }
            }
            if let path, let e = entries[path] {
                let selfClosing = tag.hasSuffix("/>")
                var opening = String(selfClosing ? tag.dropLast(2) : tag.dropLast(1))
                opening += " manifest:size=\"\(e.size)\">"
                opening += "<manifest:encryption-data manifest:checksum-type=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0#sha256-1k\" manifest:checksum=\"\(e.checksum.base64EncodedString())\">"
                opening += "<manifest:algorithm manifest:algorithm-name=\"http://www.w3.org/2001/04/xmlenc#aes256-cbc\" manifest:initialisation-vector=\"\(e.iv.base64EncodedString())\"/>"
                opening += "<manifest:key-derivation manifest:key-derivation-name=\"PBKDF2\" manifest:key-size=\"32\" manifest:iteration-count=\"\(iterations)\" manifest:salt=\"\(e.salt.base64EncodedString())\"/>"
                opening += "<manifest:start-key-generation manifest:start-key-generation-name=\"http://www.w3.org/2000/09/xmldsig#sha256\" manifest:key-size=\"32\"/>"
                opening += "</manifest:encryption-data>"
                if selfClosing { opening += "</manifest:file-entry>" }
                out += opening
            } else {
                out += tag
            }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}
