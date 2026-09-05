import Foundation
import Testing
@testable import SheetCore
@testable import SheetODS
@testable import SheetXLSX
import SwiftSheets

/// Spec §1.3 puts encrypted files and the legacy `.xls` generation outside the scope, and §14.11 asks that they
/// fail *explicitly*. Before this, a password-protected workbook looked exactly like a broken one — the same
/// `corruptedContainer` a truncated ZIP gets — which sends the reader looking for a fault in their file.
///
/// The fixtures are made by `Tests/FixtureGenerator/make_encrypted_fixtures.py` (password "swiftsheets");
/// `agile.xlsx` comes from msoffcrypto-tool, `legacy.xls` from LibreOffice, `protected.ods` is encrypted to
/// ODF 1.3 §4.3 by the generator itself — LibreOffice can no longer read it, which is the point.
@Suite struct EncryptedInputTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/encrypted")
    static func fixture(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }

    @Test func encryptedOOXMLSaysSoRatherThanLookingCorrupt() throws {
        let data = try Self.fixture("agile.xlsx")
        #expect(UnopenableInput.probe(data) == .encryptedOOXML)
        #expect(SheetFormat.detect(from: data) == nil)   // it is not a ZIP; nothing to detect

        for read in [{ try Workbook(data: data) }, { try Workbook(data: data, format: .xlsx) }] {
            let error = #expect(throws: SheetError.self) { _ = try read() }
            guard case .unsupportedFeature(let detail)? = error else { return #expect(Bool(false), "expected unsupportedFeature") }
            #expect(detail.contains("encrypted") && detail.contains("SheetDecrypt"), "names the fact and the product that opens it: \(detail)")
        }
    }

    /// The extension hint must not talk the facade into treating an encrypted package as CSV.
    @Test func encryptedOOXMLIsNotMistakenForTextWhenTheNameSaysCSV() throws {
        let data = try Self.fixture("agile.xlsx")
        #expect(throws: SheetError.unsupportedFeature(UnopenableInput.encryptedOOXML.reason)) {
            _ = try Workbook.read(data, options: ReadOptions(filename: "secret.csv"))
        }
    }

    @Test func legacyXLSNamesItselfInsteadOfBeingUnrecognized() throws {
        let data = try Self.fixture("legacy.xls")
        #expect(UnopenableInput.probe(data) == .legacyCompoundFile)
        #expect(throws: SheetError.unsupportedFeature(UnopenableInput.legacyCompoundFile.reason)) {
            _ = try Workbook(data: data)
        }
    }

    /// An encrypted ODF package keeps `mimetype` in the clear, so detection still says `.ods` and the reader is the
    /// one that has to notice.
    @Test func encryptedODFIsRecognisedFromItsManifest() throws {
        let data = try Self.fixture("protected.ods")
        #expect(SheetFormat.detect(from: data) == .ods)
        #expect(UnopenableInput.probe(in: try ZipInspection(data: data)) == .encryptedODF)
        for read in [{ try Workbook(data: data) }, { try ODSCodec.read(data).workbook }] {
            #expect(throws: SheetError.unsupportedFeature(UnopenableInput.encryptedODF.reason)) { _ = try read() }
        }
        #expect(UnopenableInput.encryptedODF.reason.contains("SheetDecrypt"), "the refusal names the product that opens the file")
    }

    /// The probe is only consulted once ordinary detection has come up empty, so it must not claim ordinary files.
    @Test func ordinaryFilesAreNotMistakenForEncryptedOnes() throws {
        let plain = try Data(contentsOf: PreservationTests.fixtures.appendingPathComponent("charts-and-friends.xlsx"))
        #expect(UnopenableInput.probe(plain) == nil)
        #expect(UnopenableInput.probe(in: try ZipInspection(data: plain)) == nil)
        #expect(UnopenableInput.probe(Data("a,b,c\n1,2,3\n".utf8)) == nil)
        #expect(UnopenableInput.probe(Data()) == nil)
        #expect(UnopenableInput.probe(Data(UnopenableInput.compoundFileSignature.dropLast())) == nil)

        let ods = try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/ods").appendingPathComponent(
            try FileManager.default.contentsOfDirectory(atPath: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/ods").path)
                .first { $0.hasSuffix(".ods") }!))
        #expect(UnopenableInput.probe(in: try ZipInspection(data: ods)) == nil)
    }

    /// `unrecognizedFormat` is still what genuinely unknown bytes get — the new answers are additions, not a
    /// replacement (the compound-file signature is eight bytes; seven of them prove nothing).
    @Test func unknownBytesAreStillUnrecognized() {
        #expect(throws: SheetError.unrecognizedFormat) { try Workbook(data: Data([0x00, 0x01, 0xFF, 0xFE])) }
    }
}
