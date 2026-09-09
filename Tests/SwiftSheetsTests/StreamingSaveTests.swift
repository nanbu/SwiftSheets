import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// A row-by-row write reaches the destination only when it finishes (spec Appendix B.51).
///
/// Every format writes into a file reserved beside the destination and renames it over at the end, so the file
/// that was already there survives a row that cannot be serialized, a closure that throws, a writer let go of, a
/// rename that fails. The failures below are injected — a fault handed to the target, a sink told to throw — and
/// each test proves the injection point was actually reached rather than trusting a disk to fill up.
@Suite struct StreamingSaveTests {
    static let formats: [SheetFormat] = [.xlsx, .xlsm, .ods, .numbers, .csv]

    static func directory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swiftsheets-save-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Everything in a directory, hidden names included — the temporary file is one.
    static func entries(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    static func rows(_ writer: StreamingWriter, count: Int = 5) throws {
        for r in 0..<count { try writer.append([.text("r\(r)"), .integer(r), .number(Decimal(r) / 4 + 1)]) }
    }

    /// An error nothing else can be mistaken for: compared by identity, so "the same error came back" means it.
    final class Marker: Error { let name: String; init(_ name: String) { self.name = name } }

    /// A sink that fails where it is told to, and remembers what was asked of it. The four real sinks are the
    /// formats' business; this one is how the writer's own contract is tested without waiting for a full disk.
    final class FaultSink: StreamingRowSink {
        var failAppend: Marker?
        var failAddSheet: Marker?
        /// Where each format finishes its package and closes its file handle.
        var failClose: Marker?
        private(set) var reached: [String] = []
        private(set) var rowsTaken = 0
        private(set) var isClosed = false
        private(set) var isCancelled = false
        var warnings: [ConversionWarning] = []

        func addSheet(named name: String) throws {
            if let failure = failAddSheet { reached.append("addSheet"); throw failure }
            reached.append("addSheet-ok")
        }
        func append(_ cells: [Cell]) throws {
            if let failure = failAppend { reached.append("append"); throw failure }
            rowsTaken += 1
        }
        func close() throws {
            if let failure = failClose { reached.append("close"); throw failure }
            reached.append("close-ok")
            isClosed = true
        }
        func cancel() { isCancelled = true }
    }

    /// A writer over the fault sink, writing into a real reserved file beside a real destination.
    static func faulted(_ dir: URL, name: String = "book.xlsx") throws -> (writer: StreamingWriter, sink: FaultSink, target: AtomicFileTarget) {
        let sink = FaultSink()
        let target = try AtomicFileTarget(destination: dir.appendingPathComponent(name))
        return (StreamingWriter(sink: sink, format: .xlsx, target: target), sink, target)
    }

    // MARK: - The destination is the last thing that happens

    /// Rows are written, the old file is still the old file — and then `close()` replaces it in one step.
    @Test(arguments: formats) func theOldFileSurvivesUntilTheWriterCloses(format: SheetFormat) throws {
        let dir = Self.directory()
        let url = dir.appendingPathComponent("book.\(format.fileExtension)")
        let old = Data("not a spreadsheet at all".utf8)
        try old.write(to: url)

        let writer = try StreamingWriter(url: url, format: format, sheetName: "S")
        try Self.rows(writer)
        #expect(try Data(contentsOf: url) == old, "\(format): the destination changed while rows were still arriving")
        // the file being written is beside the destination, on the same file system, so the replace is a rename
        #expect(Self.entries(dir).count == 2)

        let result = try writer.close()
        #expect(result.format == format)
        #expect(Self.entries(dir) == ["book.\(format.fileExtension)"], "\(format): the temporary file outlived the save")
        let workbook = try Workbook(contentsOf: url)
        #expect(workbook.sheets[0][0, 0] == .text("r0"))
        #expect(workbook.sheets[0].table.rowCount == 5)
    }

    /// A destination that did not exist does not appear until the file is complete.
    @Test(arguments: formats) func aNewDestinationAppearsOnlyWhenItIsWhole(format: SheetFormat) throws {
        let dir = Self.directory()
        let url = dir.appendingPathComponent("new.\(format.fileExtension)")
        let writer = try StreamingWriter(url: url, format: format, sheetName: "S")
        try Self.rows(writer)
        #expect(!FileManager.default.fileExists(atPath: url.path), "\(format): the destination existed before close()")
        _ = try writer.close()
        #expect(FileManager.default.fileExists(atPath: url.path))
        // both ways of reading it agree the file is whole
        let reader = try CodecSet.all.streamingReader(contentsOf: url)
        var seen = 0
        try reader.forEachRow(inSheet: reader.sheetNames[0]) { _ in seen += 1 }
        #expect(seen == 5)
    }

    /// A closure that throws saves nothing, in any format, and hands its own error back untouched.
    @Test(arguments: formats) func aClosureThatThrowsLeavesTheOldFileExactly(format: SheetFormat) throws {
        let dir = Self.directory()
        let url = dir.appendingPathComponent("book.\(format.fileExtension)")
        let old = Data("the file that was already there".utf8)
        try old.write(to: url)
        let mine = Marker("the caller's own")

        let thrown = #expect(throws: Marker.self) {
            try CodecSet.all.withStreamingWriter(to: url, as: format, sheetName: "S") { writer in
                try Self.rows(writer)
                throw mine
            }
        }
        #expect(thrown === mine)
        #expect(try Data(contentsOf: url) == old, "\(format): the destination changed after a failed write")
        #expect(Self.entries(dir) == ["book.\(format.fileExtension)"], "\(format): the temporary file was left behind")
    }

    /// The closure returning is what saves; the result's warnings are the writer's, as of the save.
    @Test func theClosureReturningIsWhatSaves() throws {
        let dir = Self.directory()
        let url = dir.appendingPathComponent("sheet.csv")
        var writerSeen: StreamingWriter?
        let result = try CodecSet.all.withStreamingWriter(to: url, sheetName: "S") { writer in
            writerSeen = writer
            try writer.append([.text("a")])
            try writer.append([CellValue.formula(FormulaExpr.parse("=SUM(A1:A1)"), cached: nil)])   // nowhere to put it
        }
        #expect(result.format == .csv)
        #expect(!result.warnings.isEmpty, "the save carried no warning for a formula written as text")
        #expect(result.warnings.map(\.message) == writerSeen?.warnings.map(\.message))
        #expect(try Workbook(contentsOf: url).sheets[0][0, 0] == .text("a"))
    }

    // MARK: - Failures, one injection point at a time

    /// A row that cannot be written ends the writer: nothing more is taken, nothing is saved, and the error is
    /// the sink's own.
    @Test func aRowThatFailsEndsTheWriter() throws {
        let dir = Self.directory()
        let (writer, sink, target) = try Self.faulted(dir)
        try writer.append([.text("fine")])
        let failure = Marker("row")
        sink.failAppend = failure

        let thrown = #expect(throws: Marker.self) { try writer.append([.text("no")]) }
        #expect(thrown === failure)
        #expect(sink.reached.contains("append"), "the injected append failure was never reached")
        #expect(throws: SheetError.self) { try writer.append([.text("after")]) }
        #expect(throws: SheetError.self) { _ = try writer.close() }
        #expect(!sink.isClosed)
        // the failure ends the writing; the file it had reserved goes when the writer is cancelled or let go of
        try writer.cancel()
        #expect(sink.isCancelled)
        #expect(Self.entries(dir).isEmpty, "the reserved file outlived the failure")
        #expect(!FileManager.default.fileExists(atPath: target.destination.path))
    }

    /// The same for a sheet that cannot be started.
    @Test func aSheetThatFailsEndsTheWriter() throws {
        let dir = Self.directory()
        let (writer, sink, _) = try Self.faulted(dir)
        let failure = Marker("sheet")
        sink.failAddSheet = failure
        let thrown = #expect(throws: Marker.self) { try writer.addSheet(named: "Two") }
        #expect(thrown === failure)
        #expect(sink.reached.contains("addSheet"))
        #expect(throws: SheetError.self) { _ = try writer.close() }
        try writer.cancel()
        #expect(Self.entries(dir).isEmpty)
    }

    /// A `close()` that fails half way — the package's own ending, the file handle — saves nothing and cleans up.
    @Test func aCloseThatFailsSavesNothing() throws {
        let dir = Self.directory()
        let (writer, sink, target) = try Self.faulted(dir)
        try Self.rows(writer)
        let failure = Marker("close")
        sink.failClose = failure

        let thrown = #expect(throws: Marker.self) { _ = try writer.close() }
        #expect(thrown === failure)
        #expect(sink.reached.contains("close"))
        #expect(sink.isCancelled)
        #expect(Self.entries(dir).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: target.destination.path))
        // and it stays failed: a second close does not quietly succeed
        #expect(throws: SheetError.self) { _ = try writer.close() }
    }

    /// A rename that fails leaves the destination as it was, and does not fall back to deleting it first.
    @Test func aRenameThatFailsLeavesTheDestination() throws {
        let dir = Self.directory()
        let (writer, sink, target) = try Self.faulted(dir)
        let old = Data("the file that was already there".utf8)
        try old.write(to: target.destination)
        try Self.rows(writer)
        let failure = Marker("rename")
        target.faults.commit = failure

        let thrown = #expect(throws: Marker.self) { _ = try writer.close() }
        #expect(thrown === failure)
        #expect(target.firedFaults == ["commit"], "the injected rename failure was never reached")
        #expect(sink.reached.contains("close-ok"), "the package was not finished before the rename was tried")
        #expect(try Data(contentsOf: target.destination) == old)
        #expect(Self.entries(dir) == ["book.xlsx"], "the finished temporary file was not cleaned up")
    }

    /// A failure whose cleanup fails too keeps both: the cause is not lost behind the tidying up.
    @Test func bothHalvesOfADoubleFailureSurvive() throws {
        let dir = Self.directory()
        let (writer, sink, target) = try Self.faulted(dir)
        try Self.rows(writer)
        let closeFailure = Marker("close")
        let cleanupFailure = Marker("cleanup")
        sink.failClose = closeFailure
        target.faults.discard = cleanupFailure

        let thrown = #expect(throws: StreamingCleanupError.self) { _ = try writer.close() }
        #expect(thrown?.primaryError as? Marker === closeFailure)
        #expect(thrown?.cleanupErrors.count == 1)
        #expect((thrown?.cleanupErrors.first as? Marker) === cleanupFailure)
        #expect(target.firedFaults == ["discard"], "the injected cleanup failure was never reached")
        #expect(!FileManager.default.fileExists(atPath: target.destination.path), "a failed write created the destination")
        #expect(Self.entries(dir).count == 1, "the file left behind is the temporary one, as documented")
    }

    /// Cancelling says so when the cleanup fails, and tries again next time rather than pretending it is done.
    @Test func aCancelThatCannotCleanUpSaysSo() throws {
        let dir = Self.directory()
        let (writer, sink, target) = try Self.faulted(dir)
        try Self.rows(writer)
        let cleanupFailure = Marker("cleanup")
        target.faults.discard = cleanupFailure

        let thrown = #expect(throws: Marker.self) { try writer.cancel() }
        #expect(thrown === cleanupFailure)
        #expect(sink.isCancelled)
        #expect(Self.entries(dir).count == 1)

        target.faults.discard = nil
        try writer.cancel()   // what was left of the cleanup, tried again
        #expect(Self.entries(dir).isEmpty)
        #expect(target.firedFaults == ["discard"])
    }

    /// A destination the library will not write: a directory, a symbolic link, a directory that is not there.
    /// Each is refused before anything is created.
    @Test func aDestinationThatIsNotAPlainFileIsRefused() throws {
        let dir = Self.directory()
        let folder = dir.appendingPathComponent("book.xlsx")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: SheetError.self) { _ = try StreamingWriter(url: folder) }

        let real = dir.appendingPathComponent("real.xlsx")
        try Data("real".utf8).write(to: real)
        let link = dir.appendingPathComponent("link.xlsx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: SheetError.self) { _ = try StreamingWriter(url: link) }
        #expect(try Data(contentsOf: real) == Data("real".utf8))

        #expect(throws: SheetError.self) { _ = try StreamingWriter(url: dir.appendingPathComponent("nope/book.xlsx")) }
        #expect(Self.entries(dir).sorted() == ["book.xlsx", "link.xlsx", "real.xlsx"])
    }

    // MARK: - Using it wrongly

    /// Closing twice saves once and answers the same thing; the file is not written again.
    @Test func closingTwiceSavesOnce() throws {
        let dir = Self.directory()
        let url = dir.appendingPathComponent("book.csv")
        let writer = try StreamingWriter(url: url, sheetName: "S")
        try Self.rows(writer)
        let first = try writer.close()
        let planted = Data("someone else wrote this afterwards".utf8)
        try planted.write(to: url)

        let again = try writer.close()
        #expect(again.format == first.format && again.warnings.count == first.warnings.count)
        #expect(try Data(contentsOf: url) == planted, "the second close() wrote the file again")
    }

    /// A finished writer takes no more rows, and cancelling it does not delete what it saved.
    @Test func aFinishedWriterIsOver() throws {
        let dir = Self.directory()
        let url = dir.appendingPathComponent("book.csv")
        let writer = try StreamingWriter(url: url, sheetName: "S")
        try Self.rows(writer)
        _ = try writer.close()
        #expect(throws: SheetError.self) { try writer.append([.text("more")]) }
        #expect(throws: SheetError.self) { try writer.addSheet(named: "Two") }
        try writer.cancel()
        #expect(FileManager.default.fileExists(atPath: url.path), "cancel() deleted a file that was already saved")
    }

    /// The closure may not end the writer itself — and catching that refusal does not get the file saved.
    @Test func theClosureMayNotCloseOrCancel() throws {
        let dir = Self.directory()
        let url = dir.appendingPathComponent("book.csv")
        #expect(throws: SheetError.self) {
            try CodecSet.all.withStreamingWriter(to: url, sheetName: "S") { writer in
                try Self.rows(writer)
                _ = try writer.close()
            }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let swallowed = dir.appendingPathComponent("swallowed.csv")
        #expect(throws: SheetError.self) {
            try CodecSet.all.withStreamingWriter(to: swallowed, sheetName: "S") { writer in
                try Self.rows(writer)
                do { try writer.cancel() } catch { /* the closure decides to carry on regardless */ }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: swallowed.path))
        #expect(Self.entries(dir).isEmpty)
    }

    /// A closure that catches its own write failure and returns still saves nothing: the recorded failure is the
    /// answer.
    @Test func aSwallowedFailureIsStillAFailure() throws {
        let dir = Self.directory()
        let url = dir.appendingPathComponent("one.csv")
        let thrown = #expect(throws: SheetError.self) {
            try CodecSet.all.withStreamingWriter(to: url, sheetName: "S") { writer in
                try writer.append([.text("a")])
                do { try writer.addSheet(named: "Two") } catch { /* delimited text holds one sheet */ }
            }
        }
        if case .unsupportedFeature(let detail) = thrown { #expect(detail.contains("one sheet")) } else { Issue.record("the recorded failure was replaced: \(String(describing: thrown))") }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(Self.entries(dir).isEmpty)
    }

    /// A writer kept past the closure is over: it saved once, and takes no more rows.
    @Test func aWriterKeptPastTheClosureIsOver() throws {
        let dir = Self.directory()
        let url = dir.appendingPathComponent("book.csv")
        var escaped: StreamingWriter?
        let result = try CodecSet.all.withStreamingWriter(to: url, sheetName: "S") { writer in
            escaped = writer
            try Self.rows(writer)
        }
        #expect(result.format == .csv)
        #expect(throws: SheetError.self) { try escaped?.append([.text("after")]) }
        #expect(try Workbook(contentsOf: url).sheets[0].table.rowCount == 5)
    }

    /// A writer let go of without closing writes nothing and leaves nothing behind — including its temporary file.
    @Test func aWriterDroppedWithoutClosingLeavesNothing() throws {
        let dir = Self.directory()
        let url = dir.appendingPathComponent("book.xlsx")
        let old = Data("the file that was already there".utf8)
        try old.write(to: url)
        do {
            let writer = try StreamingWriter(url: url, sheetName: "S")
            try Self.rows(writer)
            #expect(Self.entries(dir).count == 2)
        }
        #expect(try Data(contentsOf: url) == old)
        #expect(Self.entries(dir) == ["book.xlsx"], "the temporary file survived the writer")
    }

    /// A format the set has no codec for is refused before anything is created: no file is reserved, and the
    /// destination is not touched.
    @Test func anUnregisteredFormatCreatesNothing() throws {
        let dir = Self.directory()
        let codecs = CodecSet([])
        #expect(throws: SheetError.self) { _ = try codecs.streamingWriter(url: dir.appendingPathComponent("book.xlsx")) }
        #expect(throws: SheetError.self) {
            _ = try codecs.withStreamingWriter(to: dir.appendingPathComponent("book.xlsx")) { _ in }
        }
        #expect(Self.entries(dir).isEmpty, "a refused format still reserved a file")
    }

    /// Two writers on one destination reserve two different files, and the last save that succeeds is what stays.
    @Test func twoWritersOnOneDestinationDoNotCollide() throws {
        let dir = Self.directory()
        let url = dir.appendingPathComponent("book.csv")
        let first = try StreamingWriter(url: url, sheetName: "S")
        let second = try StreamingWriter(url: url, sheetName: "S")
        try first.append([.text("first")])
        try second.append([.text("second")])
        #expect(Self.entries(dir).count == 2, "the two writers reserved the same name")
        _ = try first.close()
        _ = try second.close()
        #expect(try Workbook(contentsOf: url).sheets[0][0, 0] == .text("second"))
        #expect(Self.entries(dir) == ["book.csv"])
    }
}
