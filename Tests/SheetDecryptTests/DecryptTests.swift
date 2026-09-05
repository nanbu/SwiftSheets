import Foundation
import Testing
import SheetDecrypt

/// Opening protected files with the product that only decrypts (spec Appendix B.39.9, Rev 4.29). This target links
/// SheetDecrypt and nothing that encrypts — so every file here was protected by someone else: msoffcrypto-tool
/// for the Office form, the fixture generator for the ODF form (`Tests/FixtureGenerator/make_encrypted_fixtures.py`,
/// password "swiftsheets"). The plain products still refuse the same files by name.
@Suite struct DecryptTests {
    /// The fixtures are SwiftSheetsTests'; this target reads them by path rather than carrying a second copy.
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SwiftSheetsTests/Fixtures")
    static func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }
    static let password = "swiftsheets"

    /// The Office form: `decrypt` hands back the plain package, the conveniences read it, a wrong password is
    /// refused as such, and no password at all is refused by name.
    @Test func aProtectedWorkbookOpensWithItsPassword() throws {
        let data = try Data(contentsOf: Self.fixture("encrypted/agile.xlsx"))
        #expect(SheetFormat.probe(data) == .unopenable(.encryptedOOXML))
        let plain = try decrypt(data, password: Self.password)
        #expect(SheetFormat.detect(from: plain) == .xlsx, "the plain package inside is an ordinary XLSX")
        let wb = try Workbook(data: data, password: Self.password)
        #expect(wb.sheets[0].name == "Secret")
        #expect(wb.sheets[0]["A1"] == .text("こんにちは") && wb.sheets[0]["A2"] == .integer(42))
        #expect(try Workbook.read(data, password: Self.password).workbook.sheets[0].name == "Secret")
        #expect(try Workbook.inspect(data, password: Self.password).sheets.map(\.name) == ["Secret"])
        #expect(throws: SheetError.wrongPassword) { _ = try decrypt(data, password: "not it") }
        #expect(throws: SheetError.wrongPassword) { _ = try Workbook(data: data, password: "not it") }
        #expect(throws: UnopenableInput.encryptedOOXML.error) { _ = try Workbook(data: data) }
    }

    /// The OpenDocument form: the manifest names the encrypted entries; `decrypt` returns a package with them plain.
    @Test func aProtectedODSOpensWithItsPassword() throws {
        let data = try Data(contentsOf: Self.fixture("encrypted/protected.ods"))
        #expect(SheetFormat.probe(data) == .unopenable(.encryptedODF))
        let plain = try decrypt(data, password: Self.password)
        #expect(SheetFormat.probe(plain) == .spreadsheet(.ods), "the manifest of the plain package says nothing about encryption")
        let wb = try Workbook(data: data, password: Self.password)
        #expect(wb.sheets[0]["A1"] == .text("こんにちは"))
        #expect(wb.sheets[0]["A2"] == .integer(42) || wb.sheets[0]["A2"] == .number(42))
        #expect(try Workbook.inspect(data, password: Self.password).sheets[0].declaredCellCount == 2)
        #expect(throws: SheetError.wrongPassword) { _ = try Workbook(data: data, password: "not it") }
        #expect(throws: UnopenableInput.encryptedODF.error) { _ = try Workbook(data: data) }
    }

    /// The same through a URL: the file conveniences and the row-by-row reader, both forms.
    @Test func aProtectedFileOpensFromDiskAndRowByRow() throws {
        for name in ["encrypted/agile.xlsx", "encrypted/protected.ods"] {
            let url = Self.fixture(name)
            #expect(try Workbook(contentsOf: url, password: Self.password).sheets[0]["A1"] == .text("こんにちは"), "\(name)")
            #expect(try Workbook.read(contentsOf: url, password: Self.password).workbook.sheets[0]["A1"] == .text("こんにちは"), "\(name)")
            #expect(try Workbook.inspect(contentsOf: url, password: Self.password).sheets.count == 1, "\(name)")
            #expect(SheetFormat.detect(from: try decrypt(contentsOf: url, password: Self.password)) != nil, "\(name)")
            #expect(throws: SheetError.self) { _ = try StreamingReader(contentsOf: url) }
            let reader = try StreamingReader(contentsOf: url, password: Self.password)
            var first: CellValue?
            try reader.forEachRow(inSheet: reader.sheetNames[0]) { row in if first == nil { first = row.cells.first?.value } }
            #expect(first == .text("こんにちは"), "\(name)")
            #expect(try StreamingReader(data: try Data(contentsOf: url), password: Self.password).sheetNames == reader.sheetNames, "\(name)")
        }
    }

    /// Data that is not protected passes through `decrypt` untouched — a caller can give every file the password
    /// it has, as `ReadOptions.password` allowed before 0.17.0 — and the conveniences read it as the plain ones do.
    @Test func plainDataPassesThrough() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "plain"
        for format in [SheetFormat.xlsx, .ods, .csv, .numbers] {
            let plain = try wb.data(as: format)
            #expect(try decrypt(plain, password: "unused") == plain, "\(format)")
            #expect(try Workbook(data: plain, password: "unused").sheets[0]["A1"] == .text("plain"), "\(format)")
        }
        let csv = Data("a,b\n1,2\n".utf8)
        #expect(try decrypt(csv, password: "unused") == csv)
        #expect(try Workbook.read(csv, password: "unused", options: ReadOptions(filename: "t.csv")).workbook.sheets[0]["A1"] == .text("a"))
    }

    /// What `decrypt` cannot open it refuses by name, as the plain products do: a legacy .xls, a protected Numbers
    /// document. Neither is handed back as if it were plain.
    @Test func whatCannotBeOpenedIsRefusedByName() throws {
        let xls = try Data(contentsOf: Self.fixture("encrypted/legacy.xls"))
        #expect(throws: UnopenableInput.legacyCompoundFile.error) { _ = try decrypt(xls, password: "p") }
        // an ordinary Numbers document passes through; the protected shape is built, since only Numbers.app makes one
        let numbers = try Data(contentsOf: Self.fixture("numbers/test-1.numbers"))
        #expect(try decrypt(numbers, password: "p") == numbers)
        let protected = ProtectedNumbers.make()
        #expect(SheetFormat.probe(protected) == .unopenable(.encryptedNumbers))
        #expect(throws: UnopenableInput.encryptedNumbers.error) { _ = try decrypt(protected, password: "p") }
        #expect(throws: UnopenableInput.encryptedNumbers.error) { _ = try Workbook(data: protected, password: "p") }
    }
}

/// The shape of a password-protected Numbers document — an `.iwph` entry and no readable index — built here since
/// Numbers.app is the only thing that can make a real one (spec Appendix B.39.4).
enum ProtectedNumbers {
    static func make() -> Data {
        let zip = ZipWriter()
        zip.add(".iwph", Data([1, 2, 3]), stored: true)
        zip.add("Index/Document.iwa", Data([0]), stored: true)
        return zip.finish()
    }
}
