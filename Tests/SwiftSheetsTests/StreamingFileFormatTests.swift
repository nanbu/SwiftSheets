import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// A file walked row by row takes the format it was already detected as, as bytes always could (spec Appendix B.92).
/// A caller who had detected the format passed a URL and had the set sniff the file again.
@Suite struct StreamingFileFormatTests {
    static func temporary(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("streaming-format-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    @Test func aGivenFormatReadsAFileWhoseNameSaysNothing() throws {
        let url = try Self.temporary("rows.bin")
        try Data("name,count\nalpha,1\nbeta,2\n".utf8).write(to: url)
        for reader in [try CodecSet.all.streamingReader(contentsOf: url, format: .csv), try StreamingReader(contentsOf: url, format: .csv)] {
            #expect(reader.format == .csv)
            var rows: [[CellValue?]] = []
            try reader.forEachRow(inSheet: reader.sheetNames[0]) { row in rows.append(row.cells.map(\.value)) }
            #expect(rows.count == 3, "\(rows)")
            #expect(rows.last?.first == .text("beta"), "\(rows)")
        }
    }

    @Test func aGivenFormatStillRefusesACompoundFileByName() throws {
        let legacy = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/encrypted/legacy.xls")
        #expect(throws: SheetError.unopenable(.legacyCompoundFile)) {
            _ = try CodecSet.all.streamingReader(contentsOf: legacy, format: .xlsx)
        }
    }

    @Test func aFolderIsOnlyEverANumbersDocument() throws {
        let dir = try Self.temporary("not-a-bundle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(throws: SheetError.unrecognizedFormat) { _ = try CodecSet.all.streamingReader(contentsOf: dir, format: .csv) }
        #expect(throws: SheetError.unrecognizedFormat) { _ = try CodecSet.all.streamingReader(contentsOf: dir, format: .numbers) }
    }
}
