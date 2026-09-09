import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// Spec Appendix B.52. Four failures used to share `unsupportedFeature(String)`: an encrypted file, a format the
/// `CodecSet` has no codec for, a protection form this library does not handle, and a limit of the format itself.
/// A caller could only tell them apart by reading the refusal's prose. Each now has its own case, carrying the
/// value that says which — so the decision "ask for a password / link a product / stop asking" is a `switch`.
@Suite struct ErrorClassificationTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    static func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }

    /// What a caller does next. Chosen by `switch` alone: no test below reads a character of the message.
    enum NextStep: Equatable {
        case askForThePassword
        case removeTheProtectionInNumbers
        case resaveInANewerFormat
        case link(SheetFormat)
        case stopAskingForAPassword
        case somethingElse
    }

    static func nextStep(after error: SheetError) -> NextStep {
        switch error {
        case .unopenable(.encryptedOOXML), .unopenable(.encryptedODF): .askForThePassword
        case .unopenable(.encryptedNumbers): .removeTheProtectionInNumbers
        case .unopenable(.legacyCompoundFile): .resaveInANewerFormat
        case .noCodec(let format): .link(format)
        case .unsupportedEncryption: .stopAskingForAPassword
        default: .somethingElse
        }
    }

    static func step(_ body: () throws -> Void) -> NextStep {
        do { try body(); Issue.record("expected a refusal"); return .somethingElse }
        catch let error as SheetError { return nextStep(after: error) }
        catch { Issue.record("not a SheetError: \(error)"); return .somethingElse }
    }

    /// A protected .xlsx and a protected .ods both mean "ask for the password"; a protected Numbers document and a
    /// 1997–2003 .xls do not, although all four are refused at the same place with the same shape of message.
    @Test func theRefusalsAreToldApartWithoutReadingTheirText() throws {
        let ooxml = try Self.fixture("encrypted/agile.xlsx")
        let odf = try Self.fixture("encrypted/protected.ods")
        let xls = try Self.fixture("encrypted/legacy.xls")
        let numbers = { let z = ZipWriter(); z.add(".iwph", Data([1]), stored: true)
                        z.add("Index/Document.iwa", Data([0]), stored: true); return z.finish() }()

        #expect(Self.step { _ = try Workbook(data: ooxml) } == .askForThePassword)
        #expect(Self.step { _ = try Workbook(data: odf) } == .askForThePassword)
        #expect(Self.step { _ = try Workbook(data: numbers) } == .removeTheProtectionInNumbers)
        #expect(Self.step { _ = try Workbook(data: xls) } == .resaveInANewerFormat)

        // a format outside the set is a different answer with a different remedy, and it names the format
        #expect(Self.step { _ = try CodecSet([.xlsx]).read(try Self.sampleODS()) } == .link(.ods))
        // a limit of the format itself is still `unsupportedFeature`, which no branch above claims
        var lossy = Workbook()
        lossy.sheets[0]["A1"] = "😀"
        let shiftJIS = WriteOptions(csv: CSVWriteOptions(encoding: .shiftJIS))
        #expect(Self.step { _ = try CodecSet.all.write(lossy, as: .csv, options: shiftJIS) } == .somethingElse)
    }

    /// The same file, the same set, three entry points: `read`, `inspect` and `streamingReader` must not disagree
    /// about whether a package is encrypted just because one of them probes before looking for a codec.
    @Test func everyEntryPointNamesTheEncryptionWhateverTheSetHolds() throws {
        let odf = try Self.fixture("encrypted/protected.ods")
        for codecs in [CodecSet([.xlsx]), CodecSet.all, CodecSet([])] {
            #expect(Self.step { _ = try codecs.read(odf) } == .askForThePassword, "read, set: \(codecs.formats)")
            #expect(Self.step { _ = try codecs.inspect(odf) } == .askForThePassword, "inspect, set: \(codecs.formats)")
            #expect(Self.step { _ = try codecs.streamingReader(data: odf) } == .askForThePassword, "stream, set: \(codecs.formats)")
        }
        // over a file as well as over bytes
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("protected-\(UUID().uuidString).ods")
        try odf.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Self.step { _ = try CodecSet([.xlsx]).read(contentsOf: url) } == .askForThePassword)
        #expect(Self.step { _ = try CodecSet([.xlsx]).inspect(contentsOf: url) } == .askForThePassword)
        #expect(Self.step { _ = try CodecSet([.xlsx]).streamingReader(contentsOf: url) } == .askForThePassword)
    }

    /// Naming a format explicitly still reaches the codec named, and a set without it still answers `noCodec`.
    @Test func aNamedFormatIsStillTheCallersChoice() throws {
        let ods = try Self.sampleODS()
        #expect(try CodecSet.all.read(ods, format: .ods).workbook.sheets[0]["A1"] == .text("x"))
        #expect(Self.step { _ = try CodecSet([.xlsx]).read(ods, format: .ods) } == .link(.ods))
        // a compound file is refused by name even when a format is named, so "secret.csv" cannot talk its way in
        #expect(Self.step { _ = try CodecSet.all.read(try Self.fixture("encrypted/agile.xlsx"), format: .csv) } == .askForThePassword)
    }

    /// `noCodec` carries the format, and the product to link is a value rather than a phrase inside the message.
    @Test func noCodecNamesTheFormatAndTheProductToLink() throws {
        let error = #expect(throws: SheetError.self) { _ = try CodecSet([.xlsx]).read(try Self.sampleODS()) }
        #expect(error == .noCodec(for: .ods))
        #expect(SheetFormat.ods.productName == "SheetODS" && SheetFormat.numbers.productName == "SheetNumbers")
        #expect(error?.description.contains("no codec for .ods") == true)
        #expect(error?.description.contains("SheetODS") == true)
    }

    /// The refusals read exactly as they did before the cases were split — only `unsupportedFeature`'s
    /// "unsupported: " prefix is gone, because these are no longer that case.
    @Test func theWordingOfEveryRefusalIsUnchanged() throws {
        #expect(SheetError.unopenable(.encryptedOOXML).description ==
                "the OOXML package is encrypted (ECMA-376 Part 2 / MS-OFFCRYPTO); the plain products carry no cipher — decrypt it with the SheetDecrypt product first (SheetDecrypt.decrypt, or Workbook(contentsOf:password:))")
        #expect(SheetError.unopenable(.legacyCompoundFile).description ==
                "an OLE compound file: the legacy .xls (BIFF) generation is out of scope — save it as .xlsx first")
        #expect(SheetError.unopenable(.encryptedNumbers).description ==
                "the Numbers document is password-protected (an .iwph package); SwiftSheets does not decrypt Numbers documents — remove the password in Numbers first")
        #expect(SheetError.noCodec(for: .csv).description ==
                "no codec for .csv is in this CodecSet — link the SheetCSV product and name .csv in the set, or use the SwiftSheets product's CodecSet.all, which has every codec")
        #expect(SheetError.unsupportedEncryption(detail: "…").description == "unsupported protection: …")
        // and `errorDescription` (what `localizedDescription` shows) still follows `description`
        #expect((SheetError.unopenable(.encryptedODF) as LocalizedError).errorDescription == SheetError.unopenable(.encryptedODF).description)
    }

    // MARK: - samples

    static func sampleODS() throws -> Data {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        return try wb.write(as: .ods).data
    }
}
