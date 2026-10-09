import Foundation
import Testing
import SwiftSheets
@testable import SheetCore

/// A file takes `format:` as bytes do (spec Appendix B.107), with its default of nil since 2.0.0 (B.108).
struct IOConsistencyTests {
    private func url(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + suffix)
    }

    /// nil detects, a format skips detection, so an optional choice passes straight through. The extension here
    /// names no format, so only the argument can say what the file is.
    @Test func aFileTakesTheFormatAsBytesDo() throws {
        let input = url(".unknown")
        try Data("name,value\nalpha,1\n".utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        let chosen: SheetFormat? = .csv
        #expect(try Workbook.read(contentsOf: input, format: chosen).workbook.sheets[0]["A2"] == "alpha")
        #expect(try Workbook.read(Data(contentsOf: input), format: chosen).workbook.sheets[0]["A2"] == "alpha")
        #expect(try Workbook(contentsOf: input, format: .csv).sheets[0]["A1"] == "name")
        #expect(try Workbook.inspect(contentsOf: input, format: .csv).sheets.count == 1)
        #expect(try CodecSet([.csv]).read(contentsOf: input, format: .csv).workbook.sheets.count == 1)
        #expect(throws: SheetError.noCodec(for: .csv)) {
            try CodecSet([]).read(contentsOf: input, format: .csv)
        }
        // nil is detection, as it is over bytes: the content says CSV, as it does to the function without the argument
        #expect(try Workbook.read(contentsOf: input, format: nil).workbook.sourceInfo?.format == .csv)
        #expect(try Workbook.read(contentsOf: input).workbook.sourceInfo?.format == .csv)
        let reference: (URL, SheetFormat?, ReadOptions) throws -> ReadResult = Workbook.read(contentsOf:format:options:)
        #expect(try reference(input, nil, ReadOptions()).workbook.sheets[0]["A2"] == "alpha")
    }

    @Test func aNumbersFolderTakesOnlyTheNumbersFormat() throws {
        let directory = url(".numbers")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try Workbook(data: Data("name,value\nalpha,1\n".utf8), format: .csv)
        let archive = try ZipArchive(data: original.write(as: .numbers).data)
        for name in archive.names where !name.hasSuffix("/") {
            let target = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try archive.read(name).write(to: target)
        }
        let selected = CodecSet([.numbers])
        #expect(try selected.read(contentsOf: directory, format: .numbers).workbook.sheets.count == original.sheets.count)
        #expect(try selected.read(contentsOf: directory, format: nil).workbook.sheets.count == original.sheets.count)
        _ = try selected.inspect(contentsOf: directory, format: .numbers)
        #expect(throws: SheetError.unrecognizedFormat) { try selected.read(contentsOf: directory, format: .xlsx) }
        #expect(throws: SheetError.unrecognizedFormat) { try selected.inspect(contentsOf: directory, format: .csv) }
    }
}
