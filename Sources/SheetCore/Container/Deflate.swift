import Foundation
#if canImport(Compression) && !SWIFTSHEETS_ZLIB
import Compression
#else
import CZlib
#endif

/// DEFLATE — ZIP's method 8, and the one place in the library that knows how bytes are folded.
///
/// Two toolboxes speak exactly this stream, and nothing above this file can tell them apart: Apple's
/// Compression framework, and zlib, which every Linux machine already carries (and so, as it happens, does
/// every Apple SDK). Which one answers is settled at compile time — Apple's where it exists, zlib otherwise.
/// Building with `-DSWIFTSHEETS_ZLIB` takes the zlib route on a machine that has both, which is how the
/// Linux path is put under the whole test suite without a Linux machine to hand.
///
/// The stream is the raw one: no two-byte header, no Adler-32 tail. `COMPRESSION_ZLIB` is already that;
/// zlib has to be told so with `windowBits = -15`.
package enum Deflate {

    /// Expands `src` to exactly the `expectedSize` the ZIP entry claims — anything else is a corrupt entry.
    package static func decompress(_ src: Data, expectedSize: Int) throws -> Data {
        try src.withUnsafeBytes { try decompress($0, expectedSize: expectedSize) }
    }

    /// The same, over bytes that lie where they are — a mapped file's entry is not copied to be expanded.
    package static func decompress(_ src: UnsafeRawBufferPointer, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0 else { throw SheetError.corruptedContainer(detail: "negative uncompressed size") }
        guard expectedSize > 0 else { return Data() }
        guard !src.isEmpty else { throw SheetError.corruptedContainer(detail: "no compressed bytes for \(expectedSize) bytes of content") }
        guard let out = Backend.inflate(src, expectedSize: expectedSize) else {
            throw SheetError.corruptedContainer(detail: "inflate did not produce the \(expectedSize) bytes the entry claims")
        }
        return out
    }

    /// Folds `src`, or nil when the compressor declines — the writers then store the bytes as they are.
    package static func compress(_ src: Data) -> Data? {
        guard !src.isEmpty else { return nil }
        return Backend.deflate(src)
    }
}

/// A compressor fed in pieces, for the writer that never holds a whole sheet: bytes go in, whatever the
/// compressor is ready to emit comes back, and `finish()` drains what is left in its window.
package final class DeflateEncoder {
    private var stream: Backend.Stream?

    package init() throws {
        guard let s = Backend.Stream() else { throw SheetError.ioFailure(detail: "cannot start the compressor") }
        stream = s
    }

    /// The bytes the compressor is ready to emit — often none, because it is still filling its window.
    package func encode(_ data: Data) throws -> Data {
        guard let stream else { return Data() }
        guard let out = stream.encode(data) else { throw SheetError.ioFailure(detail: "compression failed") }
        return out
    }

    /// The tail of the stream. The encoder is spent afterwards.
    package func finish() throws -> Data {
        guard let stream else { return Data() }
        self.stream = nil
        guard let out = stream.finish() else { throw SheetError.ioFailure(detail: "compression failed") }
        return out
    }

    /// Throws the compressor away mid-entry, for a writer that is abandoned rather than closed.
    package func cancel() { stream = nil }
}


/// A decompressor fed in pieces, for the reader that never holds a whole part: compressed bytes go in, whatever
/// has been expanded comes back, and the declared size is a hard ceiling — a stream that wants to produce more
/// than the entry says is a corrupt entry (or a bomb), and is stopped there rather than obeyed.
package final class DeflateDecoder {
    private var stream: Backend.InflateStream?
    private let expectedSize: Int
    private(set) var produced = 0
    /// True once the stream has announced its own end.
    private(set) var finished = false

    package init(expectedSize: Int) throws {
        guard expectedSize >= 0 else { throw SheetError.corruptedContainer(detail: "negative uncompressed size") }
        guard let s = Backend.InflateStream() else { throw SheetError.ioFailure(detail: "cannot start the decompressor") }
        stream = s
        self.expectedSize = expectedSize
    }

    /// Feeds compressed bytes and returns what could be expanded from them (possibly nothing, possibly several
    /// times the input). Never more than `expectedSize` in total.
    package func decode(_ input: UnsafeRawBufferPointer) throws -> Data {
        if finished || produced >= expectedSize {
            // the entry is complete; anything further is not part of it
            if !input.isEmpty { throw SheetError.corruptedContainer(detail: "inflate produced more than the \(expectedSize) bytes the entry claims") }
            return Data()
        }
        guard let stream else { return Data() }
        guard let (out, ended) = stream.decode(input, limit: expectedSize - produced) else { throw SheetError.corruptedContainer(detail: "inflate failed") }
        produced += out.count
        if ended || produced == expectedSize { finished = true }
        return out
    }

    /// Asks for whatever the decoder still holds once the compressed bytes are exhausted.
    package func drain() throws -> Data { try decode(UnsafeRawBufferPointer(start: nil, count: 0)) }

    package func decode(_ data: Data) throws -> Data { try data.withUnsafeBytes { try decode($0) } }

    /// Called when the compressed bytes are exhausted: the entry must be complete by now.
    package func finish() throws {
        defer { stream = nil }
        guard produced == expectedSize else {
            throw SheetError.corruptedContainer(detail: "inflate produced \(produced) of the \(expectedSize) bytes the entry claims")
        }
    }
}

#if canImport(Compression) && !SWIFTSHEETS_ZLIB

/// The Apple route.
enum Backend {
    static func inflate(_ s: UnsafeRawBufferPointer, expectedSize: Int) -> Data? {
        // one byte of room past the declared size: a stream that has more to say than the entry declares fills
        // it, and is refused for that rather than silently cut to fit
        var dst = Data(count: expectedSize + 1)
        let written = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
            compression_decode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, expectedSize + 1,
                                      s.bindMemory(to: UInt8.self).baseAddress!, s.count, nil, COMPRESSION_ZLIB)
        }
        guard written == expectedSize else { return nil }
        dst.count = expectedSize
        return dst
    }

    static func deflate(_ src: Data) -> Data? {
        let capacity = src.count + 64
        var dst = Data(count: capacity)
        let written = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
            src.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        dst.count = written
        return dst
    }

    final class Stream {
        private let raw = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        private var live = false
        private var status = COMPRESSION_STATUS_OK
        private var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        init?() {
            guard compression_stream_init(raw, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                raw.deallocate()
                return nil
            }
            raw.pointee.src_size = 0
            live = true
        }

        deinit {
            if live { compression_stream_destroy(raw) }
            raw.deallocate()
        }

        func encode(_ data: Data) -> Data? {
            guard live, !data.isEmpty else { return Data() }
            var produced = Data()
            var ok = true
            data.withUnsafeBytes { (s: UnsafeRawBufferPointer) in
                raw.pointee.src_ptr = s.bindMemory(to: UInt8.self).baseAddress!
                raw.pointee.src_size = data.count
                while raw.pointee.src_size > 0 {
                    guard pump(0, into: &produced) else { ok = false; return }
                }
            }
            return ok ? produced : nil
        }

        func finish() -> Data? {
            guard live else { return Data() }
            var produced = Data()
            raw.pointee.src_size = 0
            status = COMPRESSION_STATUS_OK
            while status == COMPRESSION_STATUS_OK {
                guard pump(Int32(COMPRESSION_STREAM_FINALIZE.rawValue), into: &produced) else { return nil }
            }
            compression_stream_destroy(raw)
            live = false
            return produced
        }

        /// One turn of the compressor: whatever it puts in the buffer is appended to `out`.
        private func pump(_ flags: Int32, into out: inout Data) -> Bool {
            var failed = false
            buffer.withUnsafeMutableBufferPointer { b in
                raw.pointee.dst_ptr = b.baseAddress!
                raw.pointee.dst_size = b.count
                status = compression_stream_process(raw, flags)
                guard status != COMPRESSION_STATUS_ERROR else { failed = true; return }
                let written = b.count - raw.pointee.dst_size
                if written > 0 { out.append(b.baseAddress!, count: written) }
            }
            return !failed
        }
    }

    /// One decompressor kept between calls. `decode` returns what came out and whether the stream ended.
    final class InflateStream {
        private let raw = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        private var live = false
        private var buffer = [UInt8](repeating: 0, count: 256 * 1024)

        init?() {
            guard compression_stream_init(raw, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                raw.deallocate()
                return nil
            }
            raw.pointee.src_size = 0
            live = true
        }

        deinit {
            if live { compression_stream_destroy(raw) }
            raw.deallocate()
        }

        func decode(_ input: UnsafeRawBufferPointer, limit: Int) -> (Data, Bool)? {
            guard live else { return (Data(), true) }
            var out = Data()
            var ended = false
            raw.pointee.src_ptr = input.isEmpty ? UnsafePointer<UInt8>(bitPattern: 1)! : input.bindMemory(to: UInt8.self).baseAddress!
            raw.pointee.src_size = input.count
            var failed = false
            repeat {
                let room = Swift.min(buffer.count, limit - out.count)
                guard room > 0 else { break }
                buffer.withUnsafeMutableBufferPointer { b in
                    raw.pointee.dst_ptr = b.baseAddress!
                    raw.pointee.dst_size = room
                    let status = compression_stream_process(raw, input.isEmpty ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                    switch status {
                    case COMPRESSION_STATUS_ERROR: failed = true
                    case COMPRESSION_STATUS_END: ended = true
                    default: break
                    }
                    let written = room - raw.pointee.dst_size
                    if written > 0 { out.append(b.baseAddress!, count: written) }
                }
                if failed { return nil }
                if ended { break }
                // keep turning while the decoder still has input, or filled the whole room (there may be more)
            } while raw.pointee.src_size > 0 || out.count < limit && raw.pointee.dst_size == 0
            if ended { compression_stream_destroy(raw); live = false }
            return (out, ended)
        }
    }
}

#else

/// The zlib route. `windowBits = -15` is what makes it the raw stream ZIP wants rather than a zlib-wrapped one.
enum Backend {
    private static let rawWindowBits: Int32 = -15

    static func inflate(_ s: UnsafeRawBufferPointer, expectedSize: Int) -> Data? {
        // zlib counts in 32 bits; a bigger entry goes through the streaming decoder instead
        guard s.count <= Int(UInt32.max), expectedSize <= Int(UInt32.max) else {
            guard let decoder = try? DeflateDecoder(expectedSize: expectedSize), let out = try? decoder.decode(s), (try? decoder.finish()) != nil else { return nil }
            return out
        }
        var z = z_stream()
        guard inflateInit2_(&z, rawWindowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&z) }
        var dst = Data(count: expectedSize)
        let ok = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Bool in
            z.next_in = UnsafeMutablePointer(mutating: s.bindMemory(to: UInt8.self).baseAddress!)
            z.avail_in = uInt(s.count)
            z.next_out = d.bindMemory(to: UInt8.self).baseAddress!
            z.avail_out = uInt(expectedSize)
            let status = CZlib.inflate(&z, Z_FINISH)
            return status == Z_STREAM_END && z.avail_out == 0
        }
        return ok ? dst : nil
    }

    static func deflate(_ src: Data) -> Data? {
        guard src.count <= Int(UInt32.max) else { return nil }
        var z = z_stream()
        guard deflateInit2_(&z, Z_DEFAULT_COMPRESSION, Z_DEFLATED, rawWindowBits, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&z) }
        let capacity = Int(deflateBound(&z, uLong(src.count)))
        var dst = Data(count: capacity)
        let written = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
            src.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                z.next_in = UnsafeMutablePointer(mutating: s.bindMemory(to: UInt8.self).baseAddress!)
                z.avail_in = uInt(src.count)
                z.next_out = d.bindMemory(to: UInt8.self).baseAddress!
                z.avail_out = uInt(capacity)
                guard CZlib.deflate(&z, Z_FINISH) == Z_STREAM_END else { return 0 }
                return capacity - Int(z.avail_out)
            }
        }
        guard written > 0 else { return nil }
        dst.count = written
        return dst
    }

    final class Stream {
        private var z = z_stream()
        private var live = false
        private var status: Int32 = Z_OK
        private var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        init?() {
            guard deflateInit2_(&z, Z_DEFAULT_COMPRESSION, Z_DEFLATED, Backend.rawWindowBits, 8, Z_DEFAULT_STRATEGY,
                                ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
            live = true
        }

        deinit { if live { deflateEnd(&z) } }

        func encode(_ data: Data) -> Data? {
            guard live, !data.isEmpty else { return Data() }
            var produced = Data()
            var ok = true
            data.withUnsafeBytes { (s: UnsafeRawBufferPointer) in
                let base = UnsafeMutablePointer(mutating: s.bindMemory(to: UInt8.self).baseAddress!)
                var offset = 0
                while offset < data.count {
                    // zlib counts what it is given in 32 bits; a caller handing over more than that is fed it in turns
                    let chunk = Swift.min(data.count - offset, Int(UInt32.max))
                    z.next_in = base + offset
                    z.avail_in = uInt(chunk)
                    while z.avail_in > 0 {
                        guard pump(Z_NO_FLUSH, into: &produced) else { ok = false; return }
                    }
                    offset += chunk
                }
            }
            return ok ? produced : nil
        }

        func finish() -> Data? {
            guard live else { return Data() }
            var produced = Data()
            z.next_in = nil
            z.avail_in = 0
            repeat {
                guard pump(Z_FINISH, into: &produced), status == Z_OK || status == Z_STREAM_END else { return nil }
            } while status != Z_STREAM_END
            deflateEnd(&z)
            live = false
            return produced
        }

        /// One turn of the compressor: whatever it puts in the buffer is appended to `out`.
        private func pump(_ flush: Int32, into out: inout Data) -> Bool {
            var failed = false
            buffer.withUnsafeMutableBufferPointer { b in
                z.next_out = b.baseAddress!
                z.avail_out = uInt(b.count)
                status = CZlib.deflate(&z, flush)
                guard status != Z_STREAM_ERROR else { failed = true; return }
                let written = b.count - Int(z.avail_out)
                if written > 0 { out.append(b.baseAddress!, count: written) }
            }
            return !failed
        }
    }

    /// One decompressor kept between calls. `decode` returns what came out and whether the stream ended.
    final class InflateStream {
        private var z = z_stream()
        private var live = false
        private var buffer = [UInt8](repeating: 0, count: 256 * 1024)

        init?() {
            guard inflateInit2_(&z, Backend.rawWindowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
            live = true
        }

        deinit { if live { inflateEnd(&z) } }

        func decode(_ input: UnsafeRawBufferPointer, limit: Int) -> (Data, Bool)? {
            guard live else { return (Data(), true) }
            guard input.count <= Int(UInt32.max) else { return nil }
            var out = Data()
            var ended = false
            var failed = false
            z.next_in = input.isEmpty ? nil : UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress!)
            z.avail_in = uInt(input.count)
            repeat {
                let room = Swift.min(buffer.count, limit - out.count)
                guard room > 0 else { break }
                buffer.withUnsafeMutableBufferPointer { b in
                    z.next_out = b.baseAddress!
                    z.avail_out = uInt(room)
                    let status = CZlib.inflate(&z, Z_NO_FLUSH)
                    switch status {
                    case Z_STREAM_END: ended = true
                    case Z_OK, Z_BUF_ERROR: break
                    default: failed = true
                    }
                    let written = room - Int(z.avail_out)
                    if written > 0 { out.append(b.baseAddress!, count: written) }
                }
                if failed { return nil }
                if ended { break }
            } while z.avail_in > 0 || (out.count < limit && z.avail_out == 0)
            if ended { inflateEnd(&z); live = false }
            return (out, ended)
        }
    }
}

#endif
