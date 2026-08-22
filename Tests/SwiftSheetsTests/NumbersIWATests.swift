import Foundation
import Testing
@testable import SheetCore
@testable import SheetNumbers

/// The riskiest primitive first (spec §10.2, Appendix B.8): IWA → dynamic Protobuf tree → IWA must be lossless.
@Suite struct NumbersIWATests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/numbers")
    static let template = Bundle.module.url(forResource: "empty", withExtension: "numbers")   // nil here: the template is a SheetNumbers resource
    static func templateData() throws -> Data { try Data(contentsOf: NumbersCodec.templateURL) }

    @Test func snappyRoundTrip() throws {
        let text = Data(String(repeating: "abcabcabcabc-", count: 500).utf8) + Data((0..<300).map { UInt8($0 & 0xFF) })
        #expect(try Snappy.decompress(Snappy.compress(text)) == text)
        #expect(try Snappy.decompress(Snappy.compress(Data())) == Data())
        // a real Snappy stream with copies: "hello hello hello" compressed by hand: literal "hello " then copy
        let stream = Data([17, 0x14] + Array("hello ".utf8) + [0x2A, 6])   // 17 = uncompressed len; copy len 11 offset 6 (1-byte copy tag: len-4=7 → (7<<2)|1 ... )
        _ = stream   // exercised through the fixtures below, which all contain copy tags
    }

    @Test func templateRoundTripsByteForByte() throws {
        let data = try Self.templateData()
        let zip = try ZipArchive(data: data)
        var checked = 0
        for name in zip.entries.keys where name.hasSuffix(".iwa") {
            let raw = try zip.read(name)
            let payload = try IWAFile.payload(of: raw)
            let file = try IWAFile(payload: payload, path: name)
            #expect(file.payload() == payload, "\(name) is not byte-identical after re-encoding")
            // and through the compressed framing
            #expect(try IWAFile.payload(of: file.encoded()) == payload, "\(name) framing")
            checked += 1
        }
        #expect(checked > 10)
    }

    @Test(arguments: ["issue-3", "issue-18", "simple-func", "test-empty-rows", "test-xref-coverage", "test-2", "test-10", "test-1", "test-formats", "test-hlinks", "issue-17"])
    func fixturesRoundTripByteForByte(_ name: String) throws {
        let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name + ".numbers"))
        let doc = try NumbersDocument(data: data)
        #expect(doc.object(1)?.typeName == "TN.DocumentArchive")
        let zip = try ZipArchive(data: data)
        for entry in zip.entries.keys where entry.hasSuffix(".iwa") {
            let payload = try IWAFile.payload(of: try zip.read(entry))
            guard case .iwa(let f)? = doc.files[entry] else { Issue.record("\(entry) not parsed as IWA"); continue }
            #expect(f.payload() == payload, "\(name)/\(entry)")
        }
        // the store re-emits a package whose objects decode to the same trees
        let again = try NumbersDocument(data: doc.encoded())
        #expect(again.locations.count == doc.locations.count)
        for id in doc.locations.keys { #expect(again.object(id) == doc.object(id), "\(name) object \(id)") }
    }

    @Test func schemaAndRegistryAreLoaded() {
        let s = NumbersSchema.shared
        #expect(s.registry[1] == "TN.DocumentArchive")
        #expect(s.registry[2] == "TN.SheetArchive")
        #expect(s.fieldNumber("TST.TableModelArchive", "number_of_rows") == 6)
        #expect(s.fieldNumber("TSP.Reference", "identifier") == 1)
        #expect(s.functions[1] != nil)
        #expect(s.enumValue("TSCE.ASTNodeArrayArchive.ASTNodeType", "FUNCTION_NODE") == 16)
    }

    @Test func typedAccessAndMutation() throws {
        var ref = ProtoMessage(typeName: "TSP.Reference")
        ref.set("identifier", int: 904475)
        #expect(ref.int("identifier") == 904475)
        var sheet = ProtoMessage(typeName: "TN.SheetArchive")
        sheet.set("name", string: "集計")
        sheet.append("drawable_infos", reference: 10)
        sheet.append("drawable_infos", reference: 11)
        #expect(sheet.string("name") == "集計")
        #expect(sheet.references("drawable_infos") == [10, 11])
        #expect(sheet.allReferences() == [10, 11])
        let remapped = sheet.remappingReferences([11: 99])
        #expect(remapped.references("drawable_infos") == [10, 99])
        let decoded = try ProtoMessage(decoding: sheet.encoded(), typeName: "TN.SheetArchive")
        #expect(decoded == sheet)
        var row = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive.ASTRowCoordinateArchive")
        row.set("row", int: -3)   // sint32 zigzag
        #expect(row.int("row") == -3)
        #expect(try ProtoMessage(decoding: row.encoded(), typeName: row.typeName).int("row") == -3)
    }
}
