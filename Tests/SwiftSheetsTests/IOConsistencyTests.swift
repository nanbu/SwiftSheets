import Foundation
import Testing
import SwiftSheets
@testable import SheetCore

/// The 2.0 entry points (spec Appendix B.108): `format:` as bytes take it (B.107), async twins of read, inspect,
/// write and convert, and cancellation that only async calls answer to.
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

    @Test @MainActor func asynchronousReadInspectWriteAndConvert() async throws {
        let source = url(".csv"), output = url(".xlsx")
        try Data("name,value\nalpha,1\n".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: output) }
        let result = try await Workbook.read(contentsOf: source)
        _ = try await Workbook.inspect(contentsOf: source, format: .csv)
        let encoded = try await result.workbook.write(as: .xlsx)
        let opened = try await CodecSet([.xlsx]).read(encoded.data, format: .xlsx)
        #expect(opened.workbook.sheets[0]["A2"] == "alpha")
        _ = try await Workbook.convert(source, to: output, as: .xlsx)
        #expect(try await CodecSet([.xlsx]).inspect(contentsOf: output).sheets.count == 1)
    }

    @Test func preCancelledOperationsNeverReplaceDestination() async throws {
        let workbook = try Workbook(data: Data("x\n1\n".utf8), format: .csv)
        let destination = url(".xlsx"), sentinel = Data("existing".utf8)
        try sentinel.write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await workbook.write(to: destination, as: .xlsx)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: destination) == sentinel)
        let readTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Workbook.read(Data("x\n1\n".utf8), format: .csv)
        }
        await #expect(throws: CancellationError.self) { try await readTask.value }
    }

    /// A synchronous call keeps 1.x behaviour on a cancelled task: it runs to completion. A save made while a task
    /// winds down — a `defer` in a SwiftUI `.task`, say — must still save; 2.0.0 as first tagged threw
    /// `CancellationError` here and left the file unwritten.
    @Test func synchronousCallsRunToCompletionOnACancelledTask() async throws {
        let destination = url(".xlsx")
        defer { try? FileManager.default.removeItem(at: destination) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            func saveAndReadBack() throws -> CellValue? {
                var workbook = Workbook()
                workbook.sheets[0]["A1"] = 42
                _ = try workbook.write(to: destination, as: .xlsx)
                return try Workbook.read(contentsOf: destination).workbook.sheets[0]["A1"]
            }
            return try saveAndReadBack()
        }
        #expect(try await task.value == 42)
    }

    /// Inside an async call, the scanner stops part-way through a long part once the task is cancelled; the same
    /// scan run synchronously on a cancelled task finishes.
    @Test func xmlScanObservesCancellationOnlyInsideAnAsyncCall() async throws {
        func scan() throws -> Int {
            let handler = CancellingXMLHandler()
            let data = Data(("<root>" + String(repeating: "<row>value</row>", count: 10_000) + "</root>").utf8)
            try SAXDriver(handler: handler).run(data, part: "synthetic.xml", engine: .scanner)
            return handler.rows
        }
        let observed = Task { try OperationCancellation.observing { try scan() } }
        await #expect(throws: CancellationError.self) { try await observed.value }
        let unobserved = Task { try scan() }
        #expect(try await unobserved.value == 10_000)
    }
}

private final class CancellingXMLHandler: SAXHandler {
    var driver: SAXDriver?
    var rootAttributes: [String: String] = [:]
    var rows = 0
    func start(_ name: String, _ attrs: [String: String]) {
        guard name == "row" else { return }
        rows += 1
        if rows == 1 { withUnsafeCurrentTask { $0?.cancel() } }
    }
}
