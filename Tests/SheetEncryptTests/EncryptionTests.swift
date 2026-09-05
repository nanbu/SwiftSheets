import Foundation
import Testing
import SheetCore
import SheetODS
import SheetDecrypt
import SheetEncrypt

/// Password-protected files (spec Appendix B.39.9): a file another encryptor made opens with its password and
/// nothing else; what this library protects, it opens again, and reports as protected to a probe. Since 0.17.0
/// the protecting is the SheetEncrypt product's and the opening SheetDecrypt's (Rev 4.29); the plain suite has
/// neither, which is why this file lives in its own target.
@Suite struct EncryptionTests {
    /// The fixtures are SwiftSheetsTests' (made by `Tests/FixtureGenerator/make_encrypted_fixtures.py`); this
    /// target reads them by path rather than carrying a second copy.
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SwiftSheetsTests/Fixtures")
    static let password = "swiftsheets"

    /// The compound file on its own: streams of every size, nested storages, back exactly.
    @Test func aCompoundFileRoundTrips() throws {
        let big = Data((0..<20_000).map { UInt8($0 % 251) })
        let streams = [
            CompoundFile.StreamToWrite("Small", Data("tiny".utf8)),
            CompoundFile.StreamToWrite("Big", big),
            CompoundFile.StreamToWrite("Empty", Data()),
            CompoundFile.StreamToWrite("\u{6}Folder/Inner/Deep", Data(repeating: 7, count: 5000)),
            CompoundFile.StreamToWrite("\u{6}Folder/Sibling", Data(repeating: 9, count: 100))
        ]
        let file = try CompoundFile(data: CompoundFile.write(streams))
        for s in streams { #expect(try file.stream(s.path) == s.data, "\(s.path)") }
        #expect(Set(file.streamPaths) == Set(streams.map(\.path)))
        #expect(throws: SheetError.self) { try file.stream("Missing") }
    }

    /// The fixture msoffcrypto-tool made: the compound file reads, and the package inside opens with the password.
    @Test func aFileAnotherEncryptorMadeOpensWithItsPassword() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("encrypted/agile.xlsx"))
        let file = try CompoundFile(data: data)
        #expect(file.streamPaths.contains("EncryptionInfo") && file.streamPaths.contains("EncryptedPackage"))
        let wb = try Workbook(data: data, password: Self.password)
        #expect(wb.sheets[0].name == "Secret")
        #expect(wb.sheets[0]["A1"] == .text("こんにちは"))
        #expect(wb.sheets[0]["A2"] == .integer(42))
        #expect(throws: SheetError.wrongPassword) { _ = try Workbook(data: data, password: "not it") }
        #expect(throws: UnopenableInput.encryptedOOXML.error) { _ = try Workbook(data: data) }
        let summary = try Workbook.inspect(data, password: Self.password)
        #expect(summary.sheets.map(\.name) == ["Secret"])
    }

    /// Round trips are written with a short spin so the suite stays quick; what is read takes the count the
    /// file declares, so nothing about opening a file depends on this. One round trip keeps Excel's count.
    static func withQuickSpin<T>(_ body: () throws -> T) rethrows -> T {
        let saved = OOXMLEncryption.spinCountForNewFiles
        OOXMLEncryption.spinCountForNewFiles = 500
        defer { OOXMLEncryption.spinCountForNewFiles = saved }
        return try body()
    }

    /// What this library protects, it opens again — and only with the password. Written at full strength.
    @Test func aProtectedWorkbookRoundTrips() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "秘密"
        wb.sheets[0]["B2"] = 3.25
        wb.addSheet(named: "Two")
        wb.sheets[1]["C3"] = Formula("=1+2")
        let protected = try wb.data(as: .xlsx, password: "パスワード")
        #expect(SheetFormat.probe(protected) == .unopenable(.encryptedOOXML))
        #expect(SheetFormat.detect(from: protected) == nil)
        let back = try Workbook(data: protected, password: "パスワード")
        #expect(back.sheets[0]["A1"] == .text("秘密") && back.sheets[0]["B2"] == .number(3.25))
        #expect(back.sheets[1]["C3"]?.formula?.text == "=1+2")
        #expect(throws: SheetError.wrongPassword) { _ = try Workbook(data: protected, password: "wrong") }
        // the streaming reader takes the password too
        let reader = try StreamingReader(data: protected, password: "パスワード")
        var seen: [CellValue?] = []
        try reader.forEachRow(inSheet: "Sheet1") { seen.append(contentsOf: $0.cells.map(\.value)) }
        #expect(seen.contains(.text("秘密")))
    }

    /// A macro-enabled workbook keeps its macros through the protection.
    @Test func aProtectedMacroWorkbookKeepsItsMacros() throws {
        let source = try Data(contentsOf: Self.fixtures.appendingPathComponent("preservation/with-vba.xlsm"))
        let wb = try Workbook(data: source)
        let protected = try Self.withQuickSpin { try wb.data(as: .xlsm, password: "m") }
        let back = try Workbook(data: protected, password: "m")
        #expect(back.preserved.hasVBAProject)
        #expect(back.sourceInfo?.format == .xlsm)
    }

    /// The package inside is altered: the integrity check refuses it rather than handing over a broken file.
    @Test func aTamperedPackageIsRefused() throws {
        var wb = Workbook()
        for r in 0..<800 { wb.sheets[0].append([.integer(r), .text("row \(r)")]) }   // big enough to leave the mini stream
        var protected = try Self.withQuickSpin { try wb.data(as: .xlsx, password: "p") }
        #expect(try CompoundFile(data: protected).stream("EncryptedPackage").count >= 4096)
        // flip a byte inside the encrypted package: the first big stream starts right after the 512-byte header
        protected[512 + 100] ^= 0xFF
        let error = #expect(throws: SheetError.self) { try Workbook(data: protected, password: "p") }
        if case .corruptedContainer(let d)? = error { #expect(d.contains("integrity") || d.contains("corrupt") || d.contains("central")) }
    }

    /// The ODF fixture (encrypted to ODF 1.3 §4.3 by the generator) opens with its password.
    @Test func aProtectedODSOpensWithItsPassword() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("encrypted/protected.ods"))
        #expect(SheetFormat.probe(data) == .unopenable(.encryptedODF))
        let wb = try Workbook(data: data, password: Self.password)
        #expect(wb.sheets[0]["A1"] == .text("こんにちは"))
        #expect(wb.sheets[0]["A2"] == .integer(42) || wb.sheets[0]["A2"] == .number(42))
        #expect(throws: SheetError.wrongPassword) { _ = try Workbook(data: data, password: "not it") }
        #expect(throws: UnopenableInput.encryptedODF.error) { _ = try Workbook(data: data) }
        let summary = try Workbook.inspect(data, password: Self.password)
        #expect(summary.sheets[0].declaredCellCount == 2)
    }

    @Test func aProtectedODSRoundTrips() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "秘密"
        wb.sheets[0]["B2"] = 3.25
        wb.sheets[0].style("A1") { $0.font.bold = true }
        let protected = try wb.data(as: .ods, password: "合言葉")
        #expect(SheetFormat.detect(from: protected) == .ods, "the mimetype stays in the clear")
        #expect(SheetFormat.probe(protected) == .unopenable(.encryptedODF))
        let zip = try ZipArchive(data: protected)
        #expect(zip.entries["content.xml"]?.method == 0, "encrypted entries are stored")
        #expect(!(try zip.read("content.xml")).starts(with: Data("<?xml".utf8)), "and are not readable without the password")
        let back = try Workbook(data: protected, password: "合言葉")
        #expect(back.sheets[0]["A1"] == .text("秘密") && back.sheets[0]["B2"] == .number(3.25))
        #expect(back.sheets[0][cell: "A1"].font.bold)
        #expect(throws: SheetError.wrongPassword) { _ = try Workbook(data: protected, password: "wrong") }
    }

    /// A protected ODS this library wrote is walked row by row with its password, and refused by name without one.
    @Test func aProtectedODSIsWalkedRowByRowWithItsPassword() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "secret"
        let protected = try wb.data(as: .ods, password: "合言葉")
        #expect(throws: UnopenableInput.encryptedODF.error) { _ = try StreamingReader(data: protected) }
        let reader = try StreamingReader(data: protected, password: "合言葉")
        var first: CellValue?
        try reader.forEachRow(inSheet: "Sheet1") { first = $0.cells.first?.value }
        #expect(first == .text("secret"))
    }

    /// `encrypt` on its own: any plain package, protected the way its format protects files, opens again with
    /// `decrypt`; the two formats without a protected form say so.
    @Test func encryptAndDecryptAreInverses() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "往復"
        for format in [SheetFormat.xlsx, .ods] {
            let plain = try wb.data(as: format)
            let protected = try Self.withQuickSpin { try encrypt(plain, as: format, password: "p") }
            #expect(protected != plain)
            #expect(SheetFormat.probe(protected) == .unopenable(format == .ods ? .encryptedODF : .encryptedOOXML))
            let back = try decrypt(protected, password: "p")
            #expect(try Workbook(data: back).sheets[0]["A1"] == .text("往復"), "\(format)")
        }
        #expect(throws: SheetError.self) { _ = try encrypt(Data("a,b\n".utf8), as: .csv, password: "p") }
        #expect(throws: SheetError.self) { _ = try encrypt(Data(), as: .numbers, password: "p") }
    }

    /// A protected package past a mebibyte is still recognised as one. The compound file's directory — where the
    /// `EncryptedPackage` name lives — follows the streams, so in a file this library or Excel writes it sits past
    /// the package itself; the probe used to look only at the first mebibyte and called anything bigger a legacy
    /// .xls. Found by protecting the 200-column million-cell workbook (4.5 MB) of Appendix B.39.11 on 2026-09-05.
    @Test func aProtectedPackagePastAMebibyteIsStillRecognised() throws {
        let big = Data(repeating: 0x5A, count: 2 << 20)   // 2 MiB where the package would be
        let file = CompoundFile.write(OOXMLEncryption.dataSpaces + [
            CompoundFile.StreamToWrite("EncryptionInfo", Data(count: 64)),
            CompoundFile.StreamToWrite("EncryptedPackage", big)
        ])
        #expect(file.count > 2 << 20)
        #expect(UnopenableInput.probe(file) == .encryptedOOXML, "the directory lies past the first mebibyte")
        #expect(SheetFormat.probe(file) == .unopenable(.encryptedOOXML))
        // and end to end: a workbook whose protected package is bigger than the old window
        var wb = Workbook()
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for r in 0..<60_000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            wb.sheets[0].append([.integer(r), .text(String(seed, radix: 36))])   // incompressible enough
        }
        let protected = try Self.withQuickSpin { try wb.data(as: .xlsx, password: "big") }
        #expect(protected.count > 1 << 20, "\(protected.count) bytes")
        #expect(SheetFormat.probe(protected) == .unopenable(.encryptedOOXML))
        #expect(try Workbook(data: protected, password: "big").sheets[0].table.cells.count == 120_000)
    }

    /// Formats that have no protection say so instead of writing an unprotected file under a password.
    @Test func formatsWithoutProtectionRefuseAPassword() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        #expect(throws: SheetError.self) { _ = try wb.data(as: .csv, password: "p") }
        #expect(throws: SheetError.self) { _ = try wb.data(as: .numbers, password: "p") }
    }
}

/// Other implementations read what this library protects: msoffcrypto-tool for the Office form, the
/// `cryptography` library walking ODF 1.3 §4.3 for the OpenDocument form. Needs `uv` with both packages already
/// cached (`uv run --with msoffcrypto-tool --with cryptography …`); skips visibly otherwise.
@Suite struct EncryptionParityTests {
    static let uv = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", "\(NSHomeDirectory())/.local/bin/uv"].first { FileManager.default.fileExists(atPath: $0) }
    static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("EncryptionParity/verify_encryption.py")

    /// The judges answer offline only when uv has them cached — the check that decides whether the test runs.
    static let judgesAvailable: Bool = {
        guard let uv else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uv)
        p.arguments = ["run", "--quiet", "--offline", "--with", "msoffcrypto-tool", "--with", "cryptography", "python3", "-c", "import msoffcrypto, cryptography"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }()

    @Test(.enabled(if: EncryptionParityTests.judgesAvailable, "uv with msoffcrypto-tool and cryptography cached is not available"))
    func otherImplementationsReadWhatThisLibraryProtects() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "判定"
        wb.sheets[0]["B1"] = 12.5
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swiftsheets-encryption-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try EncryptionTests.withQuickSpin { try wb.write(to: dir.appendingPathComponent("protected.xlsx"), password: "合言葉 pass") }
        try wb.write(to: dir.appendingPathComponent("protected.ods"), password: "合言葉 pass")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.uv!)
        p.arguments = ["run", "--quiet", "--offline", "--with", "msoffcrypto-tool", "--with", "cryptography", "python3", Self.script.path, dir.path, "合言葉 pass"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        #expect(p.terminationStatus == 0, "the judges said: \(text)")
        let report = try #require(try JSONSerialization.jsonObject(with: output) as? [String: Any], "\(text)")
        let xlsx = report["protected.xlsx"] as? [String: Any]
        #expect((xlsx?["sharedStrings"] as? String)?.contains("判定") == true, "msoffcrypto-tool read the strings: \(text)")
        #expect((xlsx?["sheet1"] as? String)?.contains("12.5") == true)
        let ods = report["protected.ods"] as? [String: Any]
        #expect((ods?["content"] as? String)?.contains("判定") == true, "the ODF judge read the content: \(text)")
        #expect((ods?["encrypted"] as? [String])?.contains("content.xml") == true)
    }
}
