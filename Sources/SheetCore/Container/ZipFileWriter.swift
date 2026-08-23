import Foundation
import Compression

/// A ZIP writer that puts its bytes straight into a file, one chunk at a time.
///
/// `ZipWriter` builds the whole archive in memory, which is right for a workbook that is in memory anyway. This one
/// exists for the streaming writer, where the point is never to hold the sheet at all: an entry is opened, written
/// in pieces, and closed — the compressor keeps a window, not the data. The local header's sizes are stamped in
/// afterwards by seeking back over them, so what comes out is an ordinary archive with no data descriptors.
package final class ZipFileWriter {
    private struct Entry {
        let name: [UInt8]
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let offset: Int
    }

    private let handle: FileHandle
    private var entries: [Entry] = []
    private var offset = 0
    private let dosTime: UInt16 = 0
    private let dosDate: UInt16 = (46 << 9) | (1 << 5) | 1   // 2026-01-01, as `ZipWriter` writes

    // the entry being written
    private var currentName: [UInt8]?
    private var currentOffset = 0
    private var currentUncompressed = 0
    private var currentCompressed = 0
    private var crc = CRC32.Running()
    private var stream: UnsafeMutablePointer<compression_stream>?
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)

    package init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: url.path) else {
            throw SheetError.ioFailure(detail: "cannot open \(url.lastPathComponent) for writing")
        }
        handle = h
    }

    /// Adds a whole entry at once — for the small parts beside the streamed sheet.
    package func add(_ name: String, _ data: Data) throws {
        try beginEntry(name)
        try write(data)
        try endEntry()
    }

    package func beginEntry(_ name: String) throws {
        precondition(currentName == nil, "an entry is already open")
        let nameBytes = Array(name.utf8)
        currentName = nameBytes
        currentOffset = offset
        currentUncompressed = 0
        currentCompressed = 0
        crc = CRC32.Running()

        var header = Data()
        header.append(Zip.le32(0x0403_4b50)); header.append(Zip.le16(20)); header.append(Zip.le16(0x0800))
        header.append(Zip.le16(8))                              // deflate; patched to 0 if it did not shrink
        header.append(Zip.le16(dosTime)); header.append(Zip.le16(dosDate))
        header.append(Zip.le32(0)); header.append(Zip.le32(0)); header.append(Zip.le32(0))   // crc, sizes: stamped in later
        header.append(Zip.le16(UInt16(nameBytes.count))); header.append(Zip.le16(0))
        header.append(contentsOf: nameBytes)
        try append(header)

        let s = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        guard compression_stream_init(s, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            s.deallocate()
            throw SheetError.ioFailure(detail: "cannot start the compressor")
        }
        s.pointee.src_size = 0
        stream = s
    }

    package func write(_ data: Data) throws {
        guard currentName != nil, let s = stream else { return }
        guard !data.isEmpty else { return }
        currentUncompressed += data.count
        crc.update(data)
        var produced = Data()
        try data.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            s.pointee.src_ptr = base
            s.pointee.src_size = data.count
            while s.pointee.src_size > 0 {
                try buffer.withUnsafeMutableBufferPointer { out in
                    s.pointee.dst_ptr = out.baseAddress!
                    s.pointee.dst_size = out.count
                    let status = compression_stream_process(s, 0)
                    guard status != COMPRESSION_STATUS_ERROR else { throw SheetError.ioFailure(detail: "compression failed") }
                    let written = out.count - s.pointee.dst_size
                    if written > 0 { produced.append(out.baseAddress!, count: written) }
                }
            }
        }
        if !produced.isEmpty { currentCompressed += produced.count; try append(produced) }
    }

    package func write(_ text: String) throws { try write(Data(text.utf8)) }

    package func endEntry() throws {
        guard let nameBytes = currentName, let s = stream else { return }
        var produced = Data()
        s.pointee.src_size = 0
        var status = COMPRESSION_STATUS_OK
        repeat {
            try buffer.withUnsafeMutableBufferPointer { out in
                s.pointee.dst_ptr = out.baseAddress!
                s.pointee.dst_size = out.count
                status = compression_stream_process(s, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                guard status != COMPRESSION_STATUS_ERROR else { throw SheetError.ioFailure(detail: "compression failed") }
                let written = out.count - s.pointee.dst_size
                if written > 0 { produced.append(out.baseAddress!, count: written) }
            }
        } while status == COMPRESSION_STATUS_OK
        compression_stream_destroy(s)
        s.deallocate()
        stream = nil
        if !produced.isEmpty { currentCompressed += produced.count; try append(produced) }

        // stamp the sizes into the local header now that they are known
        let checksum = crc.value
        var patch = Data()
        patch.append(Zip.le32(checksum))
        patch.append(Zip.le32(UInt32(currentCompressed)))
        patch.append(Zip.le32(UInt32(currentUncompressed)))
        try handle.seek(toOffset: UInt64(currentOffset + 14))
        handle.write(patch)
        try handle.seekToEnd()

        entries.append(Entry(name: nameBytes, method: 8, crc: checksum, compressedSize: currentCompressed,
                             uncompressedSize: currentUncompressed, offset: currentOffset))
        currentName = nil
    }

    /// Writes the central directory and closes the file.
    package func finish() throws {
        precondition(currentName == nil, "an entry is still open")
        var cd = Data()
        for e in entries {
            cd.append(Zip.le32(0x0201_4b50)); cd.append(Zip.le16(20)); cd.append(Zip.le16(20)); cd.append(Zip.le16(0x0800))
            cd.append(Zip.le16(e.method)); cd.append(Zip.le16(dosTime)); cd.append(Zip.le16(dosDate))
            cd.append(Zip.le32(e.crc)); cd.append(Zip.le32(UInt32(e.compressedSize))); cd.append(Zip.le32(UInt32(e.uncompressedSize)))
            cd.append(Zip.le16(UInt16(e.name.count))); cd.append(Zip.le16(0)); cd.append(Zip.le16(0))
            cd.append(Zip.le16(0)); cd.append(Zip.le16(0)); cd.append(Zip.le32(0))
            cd.append(Zip.le32(UInt32(e.offset))); cd.append(contentsOf: e.name)
        }
        let cdOffset = offset
        try append(cd)
        var end = Data()
        end.append(Zip.le32(0x0605_4b50)); end.append(Zip.le16(0)); end.append(Zip.le16(0))
        end.append(Zip.le16(UInt16(entries.count))); end.append(Zip.le16(UInt16(entries.count)))
        end.append(Zip.le32(UInt32(cd.count))); end.append(Zip.le32(UInt32(cdOffset))); end.append(Zip.le16(0))
        try append(end)
        try handle.close()
    }

    /// Abandons the archive — for a writer that is thrown away without being closed.
    package func abandon() {
        if let s = stream { compression_stream_destroy(s); s.deallocate(); stream = nil }
        try? handle.close()
    }

    private func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        offset += data.count
    }
}

extension CRC32 {
    /// CRC-32 over data that arrives in pieces.
    package struct Running {
        private var c: UInt32 = 0xFFFF_FFFF
        package init() {}
        package mutating func update(_ data: Data) {
            for byte in data { c = CRC32.table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        }
        package var value: UInt32 { c ^ 0xFFFF_FFFF }
    }
}
