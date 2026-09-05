import Foundation
import SheetCore
import SheetDecrypt

/// The writing half of ECMA-376 agile encryption (spec Appendix B.39.9): the package encrypted in segments under a
/// random key, that key wrapped under the password's, the HMAC over the whole, and the compound file around it.
/// The parameters, the key derivation and the reading are SheetDecrypt's — this extension only adds the cipher's
/// forward direction, the random salts and the container's writer.
extension OOXMLEncryption {
    /// How many times the password is hashed in a file this library writes — Excel's own hundred thousand.
    /// Package-visible so that tests can round-trip many files without paying for it every time; a file is
    /// read with whatever count it declares, so lowering this changes nothing about what can be opened.
    nonisolated(unsafe) package static var spinCountForNewFiles = 100_000

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
    package static let dataSpaces: [CompoundFile.StreamToWrite] = [
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
