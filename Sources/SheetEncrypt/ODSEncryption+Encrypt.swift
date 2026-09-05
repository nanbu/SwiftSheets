import Foundation
import SheetCore
import SheetDecrypt

/// The writing half of ODF package encryption (spec Appendix B.39.9): every entry but `mimetype` and the manifest
/// deflated, padded and AES-CBC-encrypted under a key derived from the password, and the manifest rewritten to say
/// so. The reading half is SheetDecrypt's.
extension ODSEncryption {
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
