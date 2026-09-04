import Foundation

/// Where a package being written goes: a buffer that becomes `Data`, or a file on disk.
package protocol ZipOutput: AnyObject {
    var count: Int { get }
    func append(_ data: Data) throws
    func append(_ raw: UnsafeRawBufferPointer) throws
    /// Overwrites bytes already written — the local header's sizes, stamped in once an entry is complete.
    func patch(_ data: Data, at offset: Int) throws
}

final class MemoryZipOutput: ZipOutput {
    var buffer = Data()
    var count: Int { buffer.count }
    func append(_ data: Data) throws { buffer.append(data) }
    func append(_ raw: UnsafeRawBufferPointer) throws { buffer.append(contentsOf: raw) }
    func patch(_ data: Data, at offset: Int) throws {
        buffer.replaceSubrange(offset..<(offset + data.count), with: data)
    }
}

final class FileZipOutput: ZipOutput {
    private let handle: FileHandle
    private(set) var count = 0
    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: url.path) else {
            throw SheetError.ioFailure(detail: "cannot open \(url.lastPathComponent) for writing")
        }
        handle = h
    }
    func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        count += data.count
    }
    func append(_ raw: UnsafeRawBufferPointer) throws { try append(Data(raw)) }
    func patch(_ data: Data, at offset: Int) throws {
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
        try handle.seekToEnd()
    }
    func close() throws { try handle.close() }
    func abandon() { try? handle.close() }
}

/// The part of writing a ZIP that is the same wherever the bytes go: local headers, entries whole or in pieces,
/// the central directory, and the ZIP64 records when the package needs them (a part past 4 GiB, an offset past
/// 4 GiB, or more than 65,535 parts). What comes out is an ordinary archive with no data descriptors: a streamed
/// entry's sizes are stamped into its local header afterwards.
package final class ZipPackager {
    private struct Entry {
        let name: [UInt8]
        let method: UInt16
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let offset: Int
        /// The local header carries a ZIP64 extra field (streamed entries reserve one, since their sizes are not
        /// known when the header is written).
        let localZip64: Bool
    }

    let output: ZipOutput
    private var entries: [Entry] = []
    private let dosTime: UInt16 = 0
    private let dosDate: UInt16 = (46 << 9) | (1 << 5) | 1   // 2026-01-01; readers ignore it
    /// Every entry gets ZIP64 bookkeeping whether or not its numbers need it — for the test that has to see the
    /// ZIP64 path without a 4 GiB file.
    package var forceZip64 = false

    // the entry being streamed
    private var currentName: [UInt8]?
    private var currentOffset = 0
    private var currentUncompressed = 0
    private var currentCompressed = 0
    private var crc = CRC32.Running()
    private var encoder: DeflateEncoder?

    package init(output: ZipOutput) { self.output = output }

    private static let limit32 = 0xFFFF_FFFF

    // MARK: - Whole entries

    /// Adds an entry. `stored: true` writes it uncompressed (ODS needs its `mimetype` first and stored).
    package func add(_ name: String, _ data: Data, stored: Bool = false) throws {
        let crc = CRC32.checksum(data)
        var method: UInt16 = 0
        var payload = data
        if !stored, data.count > 64, let deflated = Deflate.compress(data), deflated.count < data.count { method = 8; payload = deflated }
        try addCompressed(name, payload: payload, method: method, crc: crc, uncompressedSize: data.count)
    }

    /// Adds an entry whose bytes are already folded — copied from another package as they lie, without expanding
    /// them and without folding them again.
    package func addCompressed(_ name: String, payload: Data, method: UInt16, crc: UInt32, uncompressedSize: Int) throws {
        let nameBytes = Array(name.utf8)
        let offset = output.count
        let zip64 = forceZip64 || payload.count >= ZipPackager.limit32 || uncompressedSize >= ZipPackager.limit32
        try output.append(localHeader(nameBytes, method: method, crc: crc, compressed: payload.count, uncompressed: uncompressedSize, zip64: zip64))
        try output.append(payload)
        entries.append(Entry(name: nameBytes, method: method, crc: crc, compressedSize: payload.count, uncompressedSize: uncompressedSize, offset: offset, localZip64: zip64))
    }

    // MARK: - Streamed entries

    package func beginEntry(_ name: String) throws {
        precondition(currentName == nil, "an entry is already open")
        let nameBytes = Array(name.utf8)
        currentName = nameBytes
        currentOffset = output.count
        currentUncompressed = 0
        currentCompressed = 0
        crc = CRC32.Running()
        // sizes unknown yet: zeros now, the real numbers stamped in at endEntry — into the 32-bit fields when they
        // fit, into the reserved ZIP64 extra field when they do not
        try output.append(localHeader(nameBytes, method: 8, crc: 0, compressed: 0, uncompressed: 0, zip64: true))
        encoder = try DeflateEncoder()
    }

    package func write(_ data: Data) throws {
        guard currentName != nil, let encoder else { return }
        guard !data.isEmpty else { return }
        currentUncompressed += data.count
        crc.update(data)
        let produced = try encoder.encode(data)
        if !produced.isEmpty { currentCompressed += produced.count; try output.append(produced) }
    }

    package func write(_ text: String) throws { try write(Data(text.utf8)) }

    package func endEntry() throws {
        guard let nameBytes = currentName, let encoder else { return }
        let produced = try encoder.finish()
        self.encoder = nil
        if !produced.isEmpty { currentCompressed += produced.count; try output.append(produced) }
        let checksum = crc.value
        let big = currentCompressed >= ZipPackager.limit32 || currentUncompressed >= ZipPackager.limit32
        var patch = Data()
        patch.append(Zip.le32(checksum))
        patch.append(Zip.le32(big ? 0xFFFF_FFFF : UInt32(currentCompressed)))
        patch.append(Zip.le32(big ? 0xFFFF_FFFF : UInt32(currentUncompressed)))
        try output.patch(patch, at: currentOffset + 14)
        // the reserved extra field: uncompressed then compressed, as the format orders them
        var extra = Data()
        extra.append(Zip.le64(UInt64(currentUncompressed)))
        extra.append(Zip.le64(UInt64(currentCompressed)))
        try output.patch(extra, at: currentOffset + 30 + nameBytes.count + 4)
        entries.append(Entry(name: nameBytes, method: 8, crc: checksum, compressedSize: currentCompressed,
                             uncompressedSize: currentUncompressed, offset: currentOffset, localZip64: true))
        currentName = nil
    }

    // MARK: - Finishing

    /// Writes the central directory (and the ZIP64 records when needed). The output is complete afterwards.
    package func finish() throws {
        precondition(currentName == nil, "an entry is still open")
        let cdOffset = output.count
        var needsZip64 = forceZip64 || entries.count >= 0xFFFF || cdOffset >= ZipPackager.limit32
        var cd = Data()
        for e in entries {
            let bigSizes = e.compressedSize >= ZipPackager.limit32 || e.uncompressedSize >= ZipPackager.limit32
            let bigOffset = e.offset >= ZipPackager.limit32
            let zip64 = forceZip64 || bigSizes || bigOffset
            if zip64 { needsZip64 = true }
            var extra = Data()
            if zip64 {
                extra.append(Zip.le16(0x0001)); extra.append(Zip.le16(24))
                extra.append(Zip.le64(UInt64(e.uncompressedSize))); extra.append(Zip.le64(UInt64(e.compressedSize)))
                extra.append(Zip.le64(UInt64(e.offset)))
            }
            cd.append(Zip.le32(0x0201_4b50)); cd.append(Zip.le16(zip64 ? 45 : 20)); cd.append(Zip.le16(zip64 ? 45 : 20))
            cd.append(Zip.le16(0x0800)); cd.append(Zip.le16(e.method))
            cd.append(Zip.le16(dosTime)); cd.append(Zip.le16(dosDate)); cd.append(Zip.le32(e.crc))
            cd.append(Zip.le32(zip64 ? 0xFFFF_FFFF : UInt32(e.compressedSize))); cd.append(Zip.le32(zip64 ? 0xFFFF_FFFF : UInt32(e.uncompressedSize)))
            cd.append(Zip.le16(UInt16(e.name.count))); cd.append(Zip.le16(UInt16(extra.count))); cd.append(Zip.le16(0))
            cd.append(Zip.le16(0)); cd.append(Zip.le16(0)); cd.append(Zip.le32(0))
            cd.append(Zip.le32(zip64 ? 0xFFFF_FFFF : UInt32(e.offset))); cd.append(contentsOf: e.name); cd.append(extra)
        }
        try output.append(cd)
        if needsZip64 {
            let recordOffset = output.count
            var record = Data()
            record.append(Zip.le32(0x0606_4b50)); record.append(Zip.le64(44))
            record.append(Zip.le16(45)); record.append(Zip.le16(45)); record.append(Zip.le32(0)); record.append(Zip.le32(0))
            record.append(Zip.le64(UInt64(entries.count))); record.append(Zip.le64(UInt64(entries.count)))
            record.append(Zip.le64(UInt64(cd.count))); record.append(Zip.le64(UInt64(cdOffset)))
            try output.append(record)
            var locator = Data()
            locator.append(Zip.le32(0x0706_4b50)); locator.append(Zip.le32(0)); locator.append(Zip.le64(UInt64(recordOffset))); locator.append(Zip.le32(1))
            try output.append(locator)
        }
        var end = Data()
        end.append(Zip.le32(0x0605_4b50)); end.append(Zip.le16(0)); end.append(Zip.le16(0))
        let count16: UInt16 = entries.count >= 0xFFFF ? 0xFFFF : UInt16(entries.count)
        end.append(Zip.le16(count16)); end.append(Zip.le16(count16))
        end.append(Zip.le32(cd.count >= ZipPackager.limit32 ? 0xFFFF_FFFF : UInt32(cd.count)))
        end.append(Zip.le32(cdOffset >= ZipPackager.limit32 ? 0xFFFF_FFFF : UInt32(cdOffset)))
        end.append(Zip.le16(0))
        try output.append(end)
    }

    package func abandon() {
        encoder?.cancel()
        encoder = nil
    }

    private func localHeader(_ name: [UInt8], method: UInt16, crc: UInt32, compressed: Int, uncompressed: Int, zip64: Bool) -> Data {
        var h = Data()
        var extra = Data()
        if zip64 {
            extra.append(Zip.le16(0x0001)); extra.append(Zip.le16(16))
            extra.append(Zip.le64(UInt64(uncompressed))); extra.append(Zip.le64(UInt64(compressed)))
        }
        let bigSizes = compressed >= ZipPackager.limit32 || uncompressed >= ZipPackager.limit32
        h.append(Zip.le32(0x0403_4b50)); h.append(Zip.le16(zip64 ? 45 : 20)); h.append(Zip.le16(0x0800)); h.append(Zip.le16(method))
        h.append(Zip.le16(dosTime)); h.append(Zip.le16(dosDate)); h.append(Zip.le32(crc))
        h.append(Zip.le32(bigSizes ? 0xFFFF_FFFF : UInt32(compressed))); h.append(Zip.le32(bigSizes ? 0xFFFF_FFFF : UInt32(uncompressed)))
        h.append(Zip.le16(UInt16(name.count))); h.append(Zip.le16(UInt16(extra.count))); h.append(contentsOf: name); h.append(extra)
        return h
    }
}

/// A ZIP built in memory: deflate (method 8), falling back to stored when folding the bytes does not shrink them.
/// Right for a workbook that is in memory anyway.
package final class ZipWriter {
    private let sink = MemoryZipOutput()
    private let packager: ZipPackager
    package init() { packager = ZipPackager(output: sink) }

    package var forceZip64: Bool {
        get { packager.forceZip64 }
        set { packager.forceZip64 = newValue }
    }

    /// Adds an entry. `stored: true` writes it uncompressed (ODS needs its `mimetype` first and stored).
    package func add(_ name: String, _ data: Data, stored: Bool = false) {
        try! packager.add(name, data, stored: stored)   // a memory sink cannot fail
    }

    /// Adds an entry copied from another package without expanding it.
    package func addCompressed(_ name: String, payload: Data, method: UInt16, crc: UInt32, uncompressedSize: Int) {
        try! packager.addCompressed(name, payload: payload, method: method, crc: crc, uncompressedSize: uncompressedSize)
    }

    package func beginEntry(_ name: String) throws { try packager.beginEntry(name) }
    package func write(_ data: Data) throws { try packager.write(data) }
    package func write(_ text: String) throws { try packager.write(text) }
    package func endEntry() throws { try packager.endEntry() }

    package func finish() -> Data {
        try! packager.finish()
        return sink.buffer
    }
}

/// A ZIP writer that puts its bytes straight into a file, one chunk at a time.
///
/// This one exists for the streaming writer, where the point is never to hold the sheet at all: an entry is
/// opened, written in pieces, and closed — the compressor keeps a window, not the data.
package final class ZipFileWriter {
    private let sink: FileZipOutput
    private let packager: ZipPackager

    package init(url: URL) throws {
        sink = try FileZipOutput(url: url)
        packager = ZipPackager(output: sink)
    }

    package var forceZip64: Bool {
        get { packager.forceZip64 }
        set { packager.forceZip64 = newValue }
    }

    /// Adds a whole entry at once — for the small parts beside the streamed sheet.
    package func add(_ name: String, _ data: Data, stored: Bool = false) throws { try packager.add(name, data, stored: stored) }
    package func addCompressed(_ name: String, payload: Data, method: UInt16, crc: UInt32, uncompressedSize: Int) throws {
        try packager.addCompressed(name, payload: payload, method: method, crc: crc, uncompressedSize: uncompressedSize)
    }
    package func beginEntry(_ name: String) throws { try packager.beginEntry(name) }
    package func write(_ data: Data) throws { try packager.write(data) }
    package func write(_ text: String) throws { try packager.write(text) }
    package func endEntry() throws { try packager.endEntry() }

    /// Writes the central directory and closes the file.
    package func finish() throws {
        try packager.finish()
        try sink.close()
    }

    /// Abandons the archive — for a writer that is thrown away without being closed.
    package func abandon() {
        packager.abandon()
        sink.abandon()
    }
}
