import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Where a container's bytes come from: a buffer already in memory (or mapped into it), or a file read in pieces.
///
/// The ZIP reader asks for ranges — the directory at the end, one entry's compressed bytes — and never for the
/// whole file. Over a buffer that is a slice; over a file it is one positioned read, so a package far larger than
/// memory can be opened, and so can one on a volume where mapping is not safe.
package protocol ByteSource: Sendable {
    /// Total number of bytes.
    var count: Int { get }
    /// Hands `body` the bytes of `range` without copying them when the source is a buffer. The pointer is valid only
    /// for the duration of `body`.
    func withBytes<R>(in range: Range<Int>, _ body: (UnsafeRawBufferPointer) throws -> R) throws -> R
}

extension ByteSource {
    /// A copy of the bytes of `range`.
    package func bytes(in range: Range<Int>) throws -> Data {
        try withBytes(in: range) { Data($0) }
    }

    /// Checks a range before it is read: negative, reversed or past the end is a corrupt container, not a crash.
    package func check(_ range: Range<Int>, what: String) throws {
        guard range.lowerBound >= 0, range.upperBound <= count else {
            throw SheetError.corruptedContainer(detail: "\(what) lies outside the file (\(range.lowerBound)..<\(range.upperBound) of \(count) bytes)")
        }
    }
}

/// Bytes already in memory — including a file mapped with `.mappedIfSafe`, which is the same to the caller.
package struct DataByteSource: ByteSource {
    package let data: Data
    package init(_ data: Data) { self.data = data }
    package var count: Int { data.count }
    package func withBytes<R>(in range: Range<Int>, _ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        try check(range, what: "a read")
        return try data.withUnsafeBytes { raw in
            try body(UnsafeRawBufferPointer(rebasing: raw[range]))
        }
    }
}

/// A file read in pieces with positioned reads (`pread`), so nothing of it is held beyond the piece asked for and
/// several readers may share it. The descriptor is opened once and closed when the source goes away.
package final class FileByteSource: ByteSource, @unchecked Sendable {
    private let descriptor: Int32
    package let count: Int
    package let url: URL

    package init(url: URL) throws {
        self.url = url
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY)
        }
        guard fd >= 0 else { throw SheetError.ioFailure(detail: "cannot open \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            close(fd)
            throw SheetError.ioFailure(detail: "cannot stat \(url.lastPathComponent)")
        }
        guard (info.st_mode & S_IFMT) != S_IFDIR else {
            close(fd)
            throw SheetError.ioFailure(detail: "\(url.lastPathComponent) is a directory")
        }
        descriptor = fd
        count = Int(info.st_size)
    }

    deinit { close(descriptor) }

    package func withBytes<R>(in range: Range<Int>, _ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        try check(range, what: "a read")
        let length = range.count
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: Swift.max(length, 1), alignment: 16)
        defer { buffer.deallocate() }
        var done = 0
        while done < length {
            let got = pread(descriptor, buffer.baseAddress! + done, length - done, off_t(range.lowerBound + done))
            if got < 0 {
                if errno == EINTR { continue }
                throw SheetError.ioFailure(detail: "read failed on \(url.lastPathComponent): \(String(cString: strerror(errno)))")
            }
            guard got > 0 else { throw SheetError.ioFailure(detail: "\(url.lastPathComponent) ended before \(range.upperBound) bytes") }
            done += got
        }
        return try body(UnsafeRawBufferPointer(rebasing: UnsafeRawBufferPointer(buffer)[0..<length]))
    }
}
