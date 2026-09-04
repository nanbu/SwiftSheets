import Foundation
import Testing
@testable import SheetCore
@testable import SheetODS
import SwiftSheets

/// Password-protected files (spec Appendix B.39.9): a file another encryptor made opens with its password and
/// nothing else; what this library protects, it opens again, and reports as protected to a probe.
@Suite struct EncryptionTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
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
        let wb = try Workbook(data: data, options: ReadOptions(password: Self.password))
        #expect(wb.sheets[0].name == "Secret")
        #expect(wb.sheets[0]["A1"] == .text("こんにちは"))
        #expect(wb.sheets[0]["A2"] == .integer(42))
        #expect(throws: SheetError.wrongPassword) { _ = try Workbook(data: data, options: ReadOptions(password: "not it")) }
        #expect(throws: SheetError.unsupportedFeature(UnopenableInput.encryptedOOXML.reason)) { _ = try Workbook(data: data) }
        let summary = try Workbook.inspect(data, options: InspectOptions(password: Self.password))
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
        let protected = try wb.data(as: .xlsx, options: WriteOptions(password: "パスワード"))
        #expect(SheetFormat.probe(protected) == .unopenable(.encryptedOOXML))
        #expect(SheetFormat.detect(from: protected) == nil)
        let back = try Workbook(data: protected, options: ReadOptions(password: "パスワード"))
        #expect(back.sheets[0]["A1"] == .text("秘密") && back.sheets[0]["B2"] == .number(3.25))
        #expect(back.sheets[1]["C3"]?.formula?.text == "=1+2")
        #expect(throws: SheetError.wrongPassword) { _ = try Workbook(data: protected, options: ReadOptions(password: "wrong")) }
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
        let protected = try Self.withQuickSpin { try wb.data(as: .xlsm, options: WriteOptions(password: "m")) }
        let back = try Workbook(data: protected, options: ReadOptions(password: "m"))
        #expect(back.preserved.hasVBAProject)
        #expect(back.sourceInfo?.format == .xlsm)
    }

    /// The package inside is altered: the integrity check refuses it rather than handing over a broken file.
    @Test func aTamperedPackageIsRefused() throws {
        var wb = Workbook()
        for r in 0..<800 { wb.sheets[0].append([.integer(r), .text("row \(r)")]) }   // big enough to leave the mini stream
        var protected = try Self.withQuickSpin { try wb.data(as: .xlsx, options: WriteOptions(password: "p")) }
        #expect(try CompoundFile(data: protected).stream("EncryptedPackage").count >= 4096)
        // flip a byte inside the encrypted package: the first big stream starts right after the 512-byte header
        protected[512 + 100] ^= 0xFF
        let error = #expect(throws: SheetError.self) { try Workbook(data: protected, options: ReadOptions(password: "p")) }
        if case .corruptedContainer(let d)? = error { #expect(d.contains("integrity") || d.contains("corrupt") || d.contains("central")) }
    }

    /// The ODF fixture (encrypted to ODF 1.3 §4.3 by the generator) opens with its password.
    @Test func aProtectedODSOpensWithItsPassword() throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("encrypted/protected.ods"))
        #expect(SheetFormat.probe(data) == .unopenable(.encryptedODF))
        let wb = try Workbook(data: data, options: ReadOptions(password: Self.password))
        #expect(wb.sheets[0]["A1"] == .text("こんにちは"))
        #expect(wb.sheets[0]["A2"] == .integer(42) || wb.sheets[0]["A2"] == .number(42))
        #expect(throws: SheetError.wrongPassword) { _ = try Workbook(data: data, options: ReadOptions(password: "not it")) }
        #expect(throws: SheetError.unsupportedFeature(UnopenableInput.encryptedODF.reason)) { _ = try Workbook(data: data) }
        let summary = try Workbook.inspect(data, options: InspectOptions(password: Self.password))
        #expect(summary.sheets[0].declaredCellCount == 2)
    }

    @Test func aProtectedODSRoundTrips() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "秘密"
        wb.sheets[0]["B2"] = 3.25
        wb.sheets[0].style("A1") { $0.font.bold = true }
        let protected = try wb.data(as: .ods, options: WriteOptions(password: "合言葉"))
        #expect(SheetFormat.detect(from: protected) == .ods, "the mimetype stays in the clear")
        #expect(SheetFormat.probe(protected) == .unopenable(.encryptedODF))
        let zip = try ZipArchive(data: protected)
        #expect(zip.entries["content.xml"]?.method == 0, "encrypted entries are stored")
        #expect(!(try zip.read("content.xml")).starts(with: Data("<?xml".utf8)), "and are not readable without the password")
        let back = try Workbook(data: protected, options: ReadOptions(password: "合言葉"))
        #expect(back.sheets[0]["A1"] == .text("秘密") && back.sheets[0]["B2"] == .number(3.25))
        #expect(back.sheets[0][cell: "A1"].font.bold)
        #expect(throws: SheetError.wrongPassword) { _ = try Workbook(data: protected, options: ReadOptions(password: "wrong")) }
    }

    /// Formats that have no protection say so instead of writing an unprotected file under a password.
    @Test func formatsWithoutProtectionRefuseAPassword() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        #expect(throws: SheetError.self) { _ = try wb.data(as: .csv, options: WriteOptions(password: "p")) }
        #expect(throws: SheetError.self) { _ = try wb.data(as: .numbers, options: WriteOptions(password: "p")) }
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
        try EncryptionTests.withQuickSpin { try wb.write(to: dir.appendingPathComponent("protected.xlsx"), options: WriteOptions(password: "合言葉 pass")) }
        try wb.write(to: dir.appendingPathComponent("protected.ods"), options: WriteOptions(password: "合言葉 pass"))
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
