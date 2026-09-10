import Foundation

/// What a row-by-row write leaves behind: the format it landed in and what that format could not carry
/// (spec Appendix B.51). Handed back by `close()` and by `withStreamingWriter`, and only once the file is saved.
///
/// It is deliberately not a `WriteResult`: there is no `data` — the file was written a row at a time precisely so
/// that it never had to be in memory — and no `suggestion`, which is a question about a workbook this writer never
/// held.
public struct StreamingWriteResult: Sendable {
    /// The format actually written: the one asked for, else the destination's extension, else XLSX.
    public let format: SheetFormat
    /// What the format could not carry as asked — final, as of the moment the file was saved. Never silent (§6).
    public let warnings: [ConversionWarning]

    package init(format: SheetFormat, warnings: [ConversionWarning]) {
        self.format = format
        self.warnings = warnings
    }
}

/// Both halves of a failure that failed again on its way out: what went wrong, and what then went wrong while
/// cleaning up after it (spec Appendix B.51). Thrown only when the second happens — a plain failure whose cleanup
/// worked throws the original error itself, unwrapped, so the usual `catch` reads the usual way.
public struct StreamingCleanupError: Error, CustomStringConvertible {
    /// What actually went wrong: the row that could not be written, the rename that failed.
    public let primaryError: any Error
    /// What went wrong afterwards — the unfinished file that could not be removed. The destination is untouched
    /// either way; what may be left behind is the temporary file beside it.
    public let cleanupErrors: [any Error]

    package init(primaryError: any Error, cleanupErrors: [any Error]) {
        self.primaryError = primaryError
        self.cleanupErrors = cleanupErrors
    }

    public var description: String {
        "\(primaryError) — and cleaning up after it failed: \(cleanupErrors.map { "\($0)" }.joined(separator: "; "))"
    }
}

/// Writes a spreadsheet of any format one row at a time, without ever building the workbook (openpyxl's
/// `write_only=True`; spec Appendix B.42). The rows are appended the same way whichever format is being written;
/// the writer that knows the format — `XLSXStreamingWriter`, `ODSStreamingWriter`, `NumbersStreamingWriter` or
/// `CSVStreamingWriter` — does the writing.
///
/// **The destination is written once, at the end** (spec Appendix B.51). The rows go into a temporary file beside
/// it, and only a `close()` that completes the file renames that over the destination. A row that cannot be
/// serialized, a full disk, a `close()` that fails half way — none of them touch the file that was already there.
///
///     let result = try CodecSet.all.withStreamingWriter(to: url, sheetName: "売上") { writer in
///         try writer.append([.text("品目"), .text("数量")])
///         for record in records { try writer.append([.text(record.name), .integer(record.quantity)]) }
///     }
///     print(result.warnings)   // the closure returned, so the file is saved
///
/// `withStreamingWriter` is the usual way in: it closes the writer when the closure returns, and cancels it when
/// the closure throws. Rows that come from several functions can still open one by hand — `StreamingWriter(to:)`
/// in the `SwiftSheets` product, `codecs.streamingWriter(to:)` on any set — and then `close()` must be called,
/// or nothing is saved.
///
/// **What it costs.** One row, the styles the rows have worn so far, and what the format has to hold until the end:
/// XLSX nothing (the sheet is compressed as it goes), ODS the rows themselves on disk until `close()` (its one part
/// puts the styles before the tables), Numbers its string list and a tile of 256 rows. The performance record has
/// the measured peaks.
///
/// **What it does not do.** Values and formatting, one grid per sheet: no merges, no notes, no charts, nothing
/// preserved. A row written cannot be gone back to. Delimited text holds one sheet, so `addSheet` is refused
/// there.
public final class StreamingWriter {
    package let sink: any StreamingRowSink
    /// The format being written.
    public let format: SheetFormat
    private let target: AtomicFileTarget

    /// Where the writer is. Not public: a caller who has to ask has already been told, by a thrown error or by a
    /// result (spec Appendix B.51).
    private enum State {
        case open
        case finished(StreamingWriteResult)
        /// The first thing that went wrong. Nothing is written after it.
        case failed(any Error)
        case cancelled
    }
    private var state = State.open
    /// True while `withStreamingWriter` owns the ending: the closure may not close or cancel.
    private var managed = false

    /// Wraps a format's own writer and the file it is writing into. Only a `CodecSet` makes one (Appendix B.44).
    package init(sink: any StreamingRowSink, format: SheetFormat, target: AtomicFileTarget) {
        self.sink = sink
        self.format = format
        self.target = target
    }

    /// Finishes the sheet being written and starts another. Delimited text holds one sheet and refuses a second.
    public func addSheet(named name: String) throws { try edit { try sink.addSheet(named: name) } }
    /// Appends a row of values, at whatever row comes next. `nil` is an empty cell.
    public func append(_ values: [CellValue?]) throws { try edit { try sink.append(values) } }
    /// Appends a row of cells, formatting and all.
    public func append(_ cells: [Cell]) throws { try edit { try sink.append(cells) } }

    /// Writes what is pending, completes the file and saves it over the destination — in that order, with nothing
    /// that can fail after the save. The result is the save's: the format written and the warnings as they stood.
    ///
    /// A writer that has already finished hands back the same result rather than saving twice. One that failed, or
    /// was cancelled, refuses: it has written nothing, and will not.
    public func close() throws -> StreamingWriteResult {
        if managed { throw refuseFromInsideTheClosure() }
        switch state {
        case .finished(let result): return result
        case .failed: throw StreamingWriter.refusal("this writer failed and saved nothing; make another one")
        case .cancelled: throw StreamingWriter.refusal("this writer was cancelled and saved nothing; make another one")
        case .open: return try finish()
        }
    }

    /// Throws the rows away: the destination is not touched, and the resources the format was holding — file
    /// handles, the temporary file, whatever the writer had spilled to disk — go now rather than at the next
    /// collection. Cleaning up is the only thing that can fail here, and it says so.
    ///
    /// Harmless after a failure (that is the point), and after a `close()` that saved: a finished file is not
    /// deleted by cancelling the writer that wrote it.
    public func cancel() throws {
        if managed { throw refuseFromInsideTheClosure() }
        switch state {
        case .finished: return
        case .cancelled: try target.discard()   // whatever cleanup was left, tried again
        case .open, .failed:
            sink.cancel()
            state = .cancelled
            try target.discard()
        }
    }

    /// What the format could not carry as asked — the running list while rows are still arriving, final once the
    /// file is saved. The saved file's list is the one on `StreamingWriteResult`. Never silent (spec §6).
    public var warnings: [ConversionWarning] {
        if case .finished(let result) = state { return result.warnings }
        return sink.warnings
    }

    deinit {
        // never a save, never a throw: a writer let go of without closing leaves the destination as it was
        switch state {
        case .open, .failed:
            sink.cancel()
            target.discardQuietly()
        case .finished, .cancelled: break
        }
    }

    // MARK: - The managed form

    /// Runs `body` and ends the writer for it: closed and saved if the closure returns, cancelled if it throws
    /// (spec Appendix B.51). Reached through `CodecSet.withStreamingWriter`.
    package func run(_ body: (StreamingWriter) throws -> Void) throws -> StreamingWriteResult {
        managed = true
        var thrown: (any Error)?
        do { try body(self) } catch { thrown = error }
        managed = false
        // the closure's own error is the answer; a write that failed inside it is the answer when it caught that
        // error and returned anyway — either way nothing is saved
        if let thrown { throw abandon(after: thrown) }
        switch state {
        case .open: return try finish()
        case .failed(let recorded): throw abandon(after: recorded)
        case .finished(let result): return result
        case .cancelled: throw StreamingWriter.refusal("this writer was cancelled and saved nothing; make another one")
        }
    }

    // MARK: - Where the saving happens

    /// `sink.close()` → the warnings as they now stand → the rename. Nothing that can fail comes after the rename.
    private func finish() throws -> StreamingWriteResult {
        do {
            try sink.close()
        } catch {
            state = .failed(error)
            throw cleaningUp(after: error)
        }
        let result = StreamingWriteResult(format: format, warnings: sink.warnings)
        do {
            try target.commit()
        } catch {
            state = .failed(error)
            throw cleaningUp(after: error)
        }
        state = .finished(result)
        return result
    }

    /// Lets go of the format's resources and the unfinished file, and answers with the error to throw: the original
    /// one, or — when the cleaning up failed too — both of them, so neither is lost.
    private func cleaningUp(after primary: any Error) -> any Error {
        var cleanupErrors: [any Error] = []
        sink.cancel()
        do { try target.discard() } catch { cleanupErrors.append(error) }
        return cleanupErrors.isEmpty ? primary : StreamingCleanupError(primaryError: primary, cleanupErrors: cleanupErrors)
    }

    private func abandon(after primary: any Error) -> any Error {
        let answer = cleaningUp(after: primary)
        state = .cancelled
        return answer
    }

    private func edit(_ body: () throws -> Void) throws {
        switch state {
        case .finished: throw StreamingWriter.refusal("this writer has finished: the file is saved, and rows cannot be added to a saved file")
        case .failed: throw StreamingWriter.refusal("this writer failed and saved nothing; make another one")
        case .cancelled: throw StreamingWriter.refusal("this writer was cancelled and saved nothing; make another one")
        case .open: break
        }
        // the first failure ends the writer: a row half-written is not a place to carry on from
        do { try body() } catch { state = .failed(error); throw error }
    }

    private func refuseFromInsideTheClosure() -> any Error {
        let error = StreamingWriter.refusal("withStreamingWriter ends the writer itself; close() and cancel() are not the closure's to call")
        if case .open = state { state = .failed(error) }
        return error
    }

    private static func refusal(_ what: String) -> SheetError { .invalidWorkbook(what) }
}
