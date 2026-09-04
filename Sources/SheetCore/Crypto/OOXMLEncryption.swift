import Foundation

/// Password protection of an Office package as ECMA-376 Part 2 and [MS-OFFCRYPTO] §2.3.4 define it — the "agile"
/// form Excel 2010 and later write: the package is AES-encrypted in 4096-byte segments under a random key, and
/// that key is itself encrypted under a key derived from the password by a hundred thousand rounds of SHA-512.
/// Both live in a compound file beside a small XML that names every parameter (spec Appendix B.39.9).
///
/// Reading takes what the XML says (any of SHA-1 / SHA-256 / SHA-512 and AES-128 / 192 / 256 in CBC); writing
/// uses what Excel itself uses (AES-256, SHA-512, 100,000 rounds). The older "standard" encryption of Excel 2007
/// and the RC4 forms before it are recognised and refused by name.
package enum OOXMLEncryption {
    static let encryptionNamespace = "http://schemas.microsoft.com/office/2006/encryption"
    static let passwordKeyEncryptor = "http://schemas.microsoft.com/office/2006/keyEncryptor/password"
    static let segmentSize = 4096
    /// How many times the password is hashed in a file this library writes — Excel's own hundred thousand.
    /// Package-visible so that tests can round-trip many files without paying for it every time; a file is
    /// read with whatever count it declares, so lowering this changes nothing about what can be opened.
    nonisolated(unsafe) package static var spinCountForNewFiles = 100_000

    // the block keys of [MS-OFFCRYPTO] §2.3.4.13 and §2.3.4.14
    static let verifierHashInputKey: [UInt8] = [0xFE, 0xA7, 0xD2, 0x76, 0x3B, 0x4B, 0x9E, 0x79]
    static let verifierHashValueKey: [UInt8] = [0xD7, 0xAA, 0x0F, 0x6D, 0x30, 0x61, 0x34, 0x4E]
    static let keyValueKey: [UInt8] = [0x14, 0x6E, 0x0B, 0xE7, 0xAB, 0xAC, 0xD0, 0xD6]
    static let hmacKeyKey: [UInt8] = [0x5F, 0xB2, 0xAD, 0x01, 0x0C, 0xB9, 0xE1, 0xF6]
    static let hmacValueKey: [UInt8] = [0xA0, 0x67, 0x7F, 0x02, 0xB2, 0x2C, 0x84, 0x33]

    enum Hash { case sha1, sha256, sha512
        var size: Int { switch self { case .sha1: 20; case .sha256: 32; case .sha512: 64 } }
        func hash(_ d: Data) -> Data { switch self { case .sha1: SHA1.hash(d); case .sha256: SHA256.hash(d); case .sha512: SHA512.hash(d) } }
        /// One round of the spin: hash(index ‖ previous), without building the message.
        func hashRound(_ index: [UInt8], _ previous: Data) -> Data {
            func run<S: HashState>(_ state: S.Type) -> Data {
                var s = S()
                index.withUnsafeBytes { s.update($0) }
                s.update(previous)
                return s.finalize()
            }
            switch self { case .sha1: return run(SHA1.State.self); case .sha256: return run(SHA256.State.self); case .sha512: return run(SHA512.State.self) }
        }
        func hmac(_ m: Data, key: Data) -> Data {
            switch self { case .sha1: HMAC<SHA1>.authenticate(m, key: key); case .sha256: HMAC<SHA256>.authenticate(m, key: key); case .sha512: HMAC<SHA512>.authenticate(m, key: key) }
        }
        init?(name: String) {
            switch name.uppercased() { case "SHA1", "SHA-1": self = .sha1; case "SHA256", "SHA-256": self = .sha256; case "SHA512", "SHA-512": self = .sha512; default: return nil }
        }
        var name: String { switch self { case .sha1: "SHA1"; case .sha256: "SHA256"; case .sha512: "SHA512" } }
    }

    /// The parameters the EncryptionInfo XML names.
    struct Parameters {
        var keyDataSalt = Data(), keyDataHash = Hash.sha512, keyBits = 256, blockSize = 16
        var encryptedHmacKey: Data?, encryptedHmacValue: Data?
        var spinCount = 100_000, passwordSalt = Data(), passwordHash = Hash.sha512, passwordKeyBits = 256, passwordBlockSize = 16
        var encryptedVerifierHashInput = Data(), encryptedVerifierHashValue = Data(), encryptedKeyValue = Data()
    }

    // MARK: - Reading

    /// The plain package inside a protected file.
    package static func decrypt(_ compound: Data, password: String) throws -> Data {
        let file = try CompoundFile(data: compound)
        let info = try file.stream("EncryptionInfo")
        guard info.count >= 8 else { throw SheetError.corruptedContainer(detail: "EncryptionInfo is too short") }
        let b = [UInt8](info.prefix(8))
        let major = Zip.u16(b, 0), minor = Zip.u16(b, 2)
        guard major == 4, minor == 4 else {
            let kind = minor == 2 ? "the 'standard' encryption of Excel 2007 (version \(major).\(minor))" : minor == 3 ? "the 'extensible' encryption (version \(major).\(minor))" : "encryption version \(major).\(minor)"
            throw SheetError.unsupportedFeature("\(kind) is not supported; only the agile encryption of Excel 2010 and later is")
        }
        let params = try parse(info.dropFirst(8))
        let key = try intermediateKey(params, password: password)
        let package = try file.stream("EncryptedPackage")
        try verifyIntegrity(params, key: key, package: package)
        return try decryptPackage(package, key: key, params: params)
    }

    static func parse(_ xml: Data) throws -> Parameters {
        final class Collector: SAXHandler {
            var driver: SAXDriver?
            var rootAttributes: [String: String] = [:]
            var keyData: [String: String]?, integrity: [String: String]?, encryptedKey: [String: String]?
            var inPasswordEncryptor = false
            func start(_ name: String, _ a: [String: String]) {
                switch name {
                case "keyData": keyData = a
                case "dataIntegrity": integrity = a
                case "keyEncryptor": inPasswordEncryptor = a["uri"] == OOXMLEncryption.passwordKeyEncryptor
                case "encryptedKey" where inPasswordEncryptor: encryptedKey = a
                default: break
                }
            }
        }
        let c = Collector()
        try c.run(Data(xml), part: "EncryptionInfo")
        guard let kd = c.keyData, let ek = c.encryptedKey else { throw SheetError.corruptedContainer(detail: "EncryptionInfo lacks keyData or a password key encryptor") }
        func base64(_ s: String?, _ what: String) throws -> Data {
            guard let s, let d = Data(base64Encoded: s) else { throw SheetError.corruptedContainer(detail: "EncryptionInfo: \(what) is not base64") }
            return d
        }
        func hash(_ s: String?) throws -> Hash {
            guard let name = s, let h = Hash(name: name) else { throw SheetError.unsupportedFeature("hash algorithm \(s ?? "?") in an encrypted package (SHA-1, SHA-256 and SHA-512 are supported)") }
            return h
        }
        var p = Parameters()
        guard kd["cipherAlgorithm"]?.uppercased() == "AES", ek["cipherAlgorithm"]?.uppercased() == "AES" else { throw SheetError.unsupportedFeature("cipher \(kd["cipherAlgorithm"] ?? "?") in an encrypted package (only AES is supported)") }
        guard kd["cipherChaining"] == "ChainingModeCBC", ek["cipherChaining"] == "ChainingModeCBC" else { throw SheetError.unsupportedFeature("cipher chaining \(kd["cipherChaining"] ?? "?") in an encrypted package (only CBC is supported)") }
        p.keyDataSalt = try base64(kd["saltValue"], "keyData salt")
        p.keyDataHash = try hash(kd["hashAlgorithm"])
        p.keyBits = Int(kd["keyBits"] ?? "") ?? 256
        p.blockSize = Int(kd["blockSize"] ?? "") ?? 16
        if let i = c.integrity {
            p.encryptedHmacKey = try base64(i["encryptedHmacKey"], "encryptedHmacKey")
            p.encryptedHmacValue = try base64(i["encryptedHmacValue"], "encryptedHmacValue")
        }
        p.spinCount = Int(ek["spinCount"] ?? "") ?? 100_000
        guard p.spinCount <= 10_000_000 else { throw SheetError.corruptedContainer(detail: "EncryptionInfo asks for \(p.spinCount) hash rounds") }
        p.passwordSalt = try base64(ek["saltValue"], "password salt")
        p.passwordHash = try hash(ek["hashAlgorithm"])
        p.passwordKeyBits = Int(ek["keyBits"] ?? "") ?? 256
        p.passwordBlockSize = Int(ek["blockSize"] ?? "") ?? 16
        p.encryptedVerifierHashInput = try base64(ek["encryptedVerifierHashInput"], "encryptedVerifierHashInput")
        p.encryptedVerifierHashValue = try base64(ek["encryptedVerifierHashValue"], "encryptedVerifierHashValue")
        p.encryptedKeyValue = try base64(ek["encryptedKeyValue"], "encryptedKeyValue")
        guard [16, 24, 32].contains(p.keyBits / 8), [16, 24, 32].contains(p.passwordKeyBits / 8), p.blockSize == 16, p.passwordBlockSize == 16 else {
            throw SheetError.unsupportedFeature("AES with \(p.keyBits)-bit keys and \(p.blockSize)-byte blocks in an encrypted package")
        }
        return p
    }

    /// [MS-OFFCRYPTO] §2.3.4.11: the password hashed `spinCount` times, then a key per purpose.
    static func passwordHash(_ params: Parameters, password: String) -> Data {
        var pw = Data()
        for unit in password.utf16 { pw.append(UInt8(unit & 0xff)); pw.append(UInt8(unit >> 8)) }
        var h = params.passwordHash.hash(params.passwordSalt + pw)
        var index = [UInt8](repeating: 0, count: 4)
        for i in 0..<params.spinCount {
            index[0] = UInt8(i & 0xff); index[1] = UInt8((i >> 8) & 0xff); index[2] = UInt8((i >> 16) & 0xff); index[3] = UInt8((i >> 24) & 0xff)
            h = params.passwordHash.hashRound(index, h)
        }
        return h
    }

    static func blockKey(_ params: Parameters, hash: Data, block: [UInt8]) -> Data {
        var k = params.passwordHash.hash(hash + Data(block))
        let size = params.passwordKeyBits / 8
        if k.count < size { k.append(Data(repeating: 0x36, count: size - k.count)) }
        return k.prefix(size)
    }

    static func iv(_ salt: Data, blockSize: Int) -> Data {
        var v = salt
        if v.count < blockSize { v.append(Data(repeating: 0x36, count: blockSize - v.count)) }
        return v.prefix(blockSize)
    }

    static func intermediateKey(_ params: Parameters, password: String) throws -> Data {
        let h = passwordHash(params, password: password)
        let iv = iv(params.passwordSalt, blockSize: params.passwordBlockSize)
        let input = try AES(key: blockKey(params, hash: h, block: verifierHashInputKey)).decryptCBC(params.encryptedVerifierHashInput, iv: iv)
        let expected = params.passwordHash.hash(input.prefix(params.passwordSalt.count))
        let stored = try AES(key: blockKey(params, hash: h, block: verifierHashValueKey)).decryptCBC(params.encryptedVerifierHashValue, iv: iv)
        guard stored.prefix(expected.count) == expected else { throw SheetError.wrongPassword }
        let key = try AES(key: blockKey(params, hash: h, block: keyValueKey)).decryptCBC(params.encryptedKeyValue, iv: iv)
        return key.prefix(params.keyBits / 8)
    }

    /// [MS-OFFCRYPTO] §2.3.4.14: the HMAC over the whole EncryptedPackage stream, when the file carries one.
    static func verifyIntegrity(_ params: Parameters, key: Data, package: Data) throws {
        guard let encryptedHmacKey = params.encryptedHmacKey, let encryptedHmacValue = params.encryptedHmacValue else { return }
        let aes = try AES(key: key)
        let hmacKey = try aes.decryptCBC(encryptedHmacKey, iv: iv(params.keyDataHash.hash(params.keyDataSalt + Data(hmacKeyKey)), blockSize: params.blockSize)).prefix(params.keyDataHash.size)
        let stored = try aes.decryptCBC(encryptedHmacValue, iv: iv(params.keyDataHash.hash(params.keyDataSalt + Data(hmacValueKey)), blockSize: params.blockSize)).prefix(params.keyDataHash.size)
        let computed = params.keyDataHash.hmac(package, key: hmacKey)
        guard computed == stored else { throw SheetError.corruptedContainer(detail: "the encrypted package's integrity check failed: the file was altered after it was protected") }
    }

    static func decryptPackage(_ package: Data, key: Data, params: Parameters) throws -> Data {
        guard package.count >= 8 else { throw SheetError.corruptedContainer(detail: "EncryptedPackage is too short") }
        let size = Int(Zip.u64([UInt8](package.prefix(8)), 0))
        let body = package.dropFirst(8)
        guard body.count >= size, body.count % 16 == 0 else { throw SheetError.corruptedContainer(detail: "EncryptedPackage declares \(size) bytes but holds \(body.count)") }
        let aes = try AES(key: key)
        var out = Data(capacity: size)
        var segment = 0
        var offset = body.startIndex
        while offset < body.endIndex {
            let end = Swift.min(offset + segmentSize, body.endIndex)
            var index = Data(count: 4)
            index.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(segment).littleEndian, as: UInt32.self) }
            let iv = iv(params.keyDataHash.hash(params.keyDataSalt + index), blockSize: params.blockSize)
            out.append(try aes.decryptCBC(Data(body[offset..<end]), iv: iv))
            offset = end
            segment += 1
        }
        return out.prefix(size)
    }

    // MARK: - Writing

    /// `package` (a plain ZIP) protected with `password`, as a compound file Excel opens.
    package static func encrypt(_ package: Data, password: String) throws -> Data {
        var params = Parameters()
        params.spinCount = spinCountForNewFiles
        params.keyDataSalt = RandomBytes.make(16)
        params.passwordSalt = RandomBytes.make(16)
        let key = RandomBytes.make(32)
        let h = passwordHash(params, password: password)
        let pwIV = iv(params.passwordSalt, blockSize: 16)
        let verifierInput = RandomBytes.make(16)
        params.encryptedVerifierHashInput = try AES(key: blockKey(params, hash: h, block: verifierHashInputKey)).encryptCBC(verifierInput, iv: pwIV)
        params.encryptedVerifierHashValue = try AES(key: blockKey(params, hash: h, block: verifierHashValueKey)).encryptCBC(params.passwordHash.hash(verifierInput), iv: pwIV)
        params.encryptedKeyValue = try AES(key: blockKey(params, hash: h, block: keyValueKey)).encryptCBC(key, iv: pwIV)

        // the package, in segments
        let aes = try AES(key: key)
        var encrypted = Data()
        encrypted.append(Zip.le64(UInt64(package.count)))
        var segment = 0
        var offset = 0
        while offset < package.count {
            let end = Swift.min(offset + segmentSize, package.count)
            var piece = Data(package[offset..<end])
            if piece.count % 16 != 0 { piece.append(Data(count: 16 - piece.count % 16)) }
            var index = Data(count: 4)
            index.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(segment).littleEndian, as: UInt32.self) }
            encrypted.append(try aes.encryptCBC(piece, iv: iv(params.keyDataHash.hash(params.keyDataSalt + index), blockSize: 16)))
            offset = end
            segment += 1
        }
        // integrity
        let hmacKey = RandomBytes.make(64)
        let encryptedHmacKey = try aes.encryptCBC(hmacKey, iv: iv(params.keyDataHash.hash(params.keyDataSalt + Data(hmacKeyKey)), blockSize: 16))
        let hmacValue = params.keyDataHash.hmac(encrypted, key: hmacKey)
        let encryptedHmacValue = try aes.encryptCBC(hmacValue, iv: iv(params.keyDataHash.hash(params.keyDataSalt + Data(hmacValueKey)), blockSize: 16))

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        xml += "<encryption xmlns=\"\(encryptionNamespace)\" xmlns:p=\"\(passwordKeyEncryptor)\" xmlns:c=\"http://schemas.microsoft.com/office/2006/keyEncryptor/certificate\">"
        xml += "<keyData saltSize=\"16\" blockSize=\"16\" keyBits=\"256\" hashSize=\"64\" cipherAlgorithm=\"AES\" cipherChaining=\"ChainingModeCBC\" hashAlgorithm=\"SHA512\" saltValue=\"\(params.keyDataSalt.base64EncodedString())\"/>"
        xml += "<dataIntegrity encryptedHmacKey=\"\(encryptedHmacKey.base64EncodedString())\" encryptedHmacValue=\"\(encryptedHmacValue.base64EncodedString())\"/>"
        xml += "<keyEncryptors><keyEncryptor uri=\"\(passwordKeyEncryptor)\">"
        xml += "<p:encryptedKey spinCount=\"\(params.spinCount)\" saltSize=\"16\" blockSize=\"16\" keyBits=\"256\" hashSize=\"64\" cipherAlgorithm=\"AES\" cipherChaining=\"ChainingModeCBC\" hashAlgorithm=\"SHA512\""
        xml += " saltValue=\"\(params.passwordSalt.base64EncodedString())\" encryptedVerifierHashInput=\"\(params.encryptedVerifierHashInput.base64EncodedString())\""
        xml += " encryptedVerifierHashValue=\"\(params.encryptedVerifierHashValue.base64EncodedString())\" encryptedKeyValue=\"\(params.encryptedKeyValue.base64EncodedString())\"/>"
        xml += "</keyEncryptor></keyEncryptors></encryption>"
        var info = Data([0x04, 0x00, 0x04, 0x00, 0x40, 0x00, 0x00, 0x00])
        info.append(contentsOf: xml.utf8)

        return CompoundFile.write(dataSpaces + [
            CompoundFile.StreamToWrite("EncryptionInfo", info),
            CompoundFile.StreamToWrite("EncryptedPackage", encrypted)
        ])
    }

    /// The DataSpaces storage every protected Office file carries: four small streams naming the transform
    /// ("Microsoft.Container.EncryptionTransform") the package went through. Their bytes are fixed — the same in
    /// every file — and these are the ones a file written by another encryptor holds.
    static let dataSpaces: [CompoundFile.StreamToWrite] = [
        CompoundFile.StreamToWrite("\u{6}DataSpaces/Version", hex("3c0000004d006900630072006f0073006f00660074002e0043006f006e007400610069006e00650072002e004400610074006100530070006100630065007300010000000100000001000000")),
        CompoundFile.StreamToWrite("\u{6}DataSpaces/DataSpaceMap", hex("08000000010000006800000001000000000000002000000045006e0063007200790070007400650064005000610063006b00610067006500320000005300740072006f006e00670045006e006300720079007000740069006f006e004400610074006100530070006100630065000000")),
        CompoundFile.StreamToWrite("\u{6}DataSpaces/DataSpaceInfo/StrongEncryptionDataSpace", hex("0800000001000000320000005300740072006f006e00670045006e006300720079007000740069006f006e005400720061006e00730066006f0072006d000000")),
        CompoundFile.StreamToWrite("\u{6}DataSpaces/TransformInfo/StrongEncryptionTransform/\u{6}Primary", hex("58000000010000004c0000007b00460046003900410033004600300033002d0035003600450046002d0034003600310033002d0042004400440035002d003500410034003100430031004400300037003200340036007d004e0000004d006900630072006f0073006f00660074002e0043006f006e007400610069006e00650072002e0045006e006300720079007000740069006f006e005400720061006e00730066006f0072006d00000001000000010000000100000000000000000000000000000004000000"))
    ]

    static func hex(_ h: String) -> Data {
        var out = Data(capacity: h.count / 2)
        var i = h.startIndex
        while i < h.endIndex { let j = h.index(i, offsetBy: 2); out.append(UInt8(h[i..<j], radix: 16)!); i = j }
        return out
    }
}
