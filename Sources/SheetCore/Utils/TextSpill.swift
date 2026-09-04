import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Text that may outgrow memory on its way to a compressor (spec Appendix B.39.7). It is kept as pieces while
/// it is small, and spilled to a temporary file once it is not — so a body of any size costs the same few
/// megabytes to hold, and disk does the holding. The pieces come back in order, one at a time.
///
/// Why not compress as we go: the ODS body has to come *after* the styles it registers while it is being made,
/// so the whole body exists before the part it belongs to can start. Spilling is what makes that cheap.
package final class TextSpill {
    package static let pieceSize = 1 << 20
    /// Past this many bytes in memory, the rest goes to a file.
    package static let spillThreshold = 8 << 20

    private var pieces: [Data] = []
    private var held = 0
    private var file: FileHandle?
    private var url: URL?
    private(set) package var count = 0

    package init() {}

    deinit {
        try? file?.close()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    package func write(_ text: String) {
        guard !text.isEmpty else { return }
        let data = Data(text.utf8)
        count += data.count
        if let file {
            file.write(data)
            return
        }
        pieces.append(data)
        held += data.count
        if held >= TextSpill.spillThreshold { spill() }
    }

    private func spill() {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("swiftsheets-spill-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: target.path, contents: nil), let handle = FileHandle(forWritingAtPath: target.path) else {
            return   // no temporary file to be had: the pieces stay in memory, which is what would have happened anyway
        }
        for piece in pieces { handle.write(piece) }
        pieces.removeAll()
        held = 0
        file = handle
        url = target
    }

    /// Hands the text back in order, in pieces of about `pieceSize` bytes.
    package func forEachPiece(_ body: (Data) throws -> Void) throws {
        if let file, let url {
            try file.synchronize()
            // read(2) into one reused buffer, not FileHandle: on Darwin, FileHandle maps what it reads and the
            // whole file stays resident until the process is done with it — the opposite of a spill
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { throw SheetError.ioFailure(detail: "cannot read the spilled rows back") }
            defer { close(fd) }
            var buffer = [UInt8](repeating: 0, count: TextSpill.pieceSize)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n < 0 { throw SheetError.ioFailure(detail: "reading the spilled rows back failed") }
                if n == 0 { return }
                try body(Data(buffer[0..<n]))
            }
        }
        for piece in pieces {
            var offset = 0
            while offset < piece.count {
                let end = Swift.min(offset + TextSpill.pieceSize, piece.count)
                try body(piece.subdata(in: offset..<end))
                offset = end
            }
        }
    }
}
