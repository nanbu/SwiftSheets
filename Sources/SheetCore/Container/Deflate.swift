import Foundation
#if canImport(Compression) && !SWIFTSHEETS_ZLIB
import Compression
#elseif os(WASI)
// WebAssembly has neither toolbox: the pure Swift route at the end of this file answers instead.
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

    /// The most one `decode` hands back when the caller sets no other cap: the size of a stored piece
    /// (`ZipEntryStream.pieceSize × 4`). A part that expands sixty-fold — an ODS content part — turned every 256 KiB
    /// of compressed bytes into a fifteen-megabyte piece before Rev 4.31, and on macOS a freed allocation of that size
    /// stays counted against the process until the system takes it back, so a streamed read grew by the inflated
    /// size of the part. Bounded pieces are small enough to be reused by the allocator instead.
    package static let pieceCap = 1 << 20

    /// Feeds compressed bytes and returns what could be expanded from them (possibly nothing, possibly several
    /// times the input), never more than `expectedSize` in total and never more than `cap` at once. When the cap
    /// stops the expansion, `consumed` says how many of the input's bytes were used; the rest are the caller's to
    /// feed again.
    package func decode(_ input: UnsafeRawBufferPointer, upTo cap: Int) throws -> (out: Data, consumed: Int) {
        if finished || produced >= expectedSize {
            // the entry is complete; anything further is not part of it
            if !input.isEmpty { throw SheetError.corruptedContainer(detail: "inflate produced more than the \(expectedSize) bytes the entry claims") }
            return (Data(), 0)
        }
        guard let stream else { return (Data(), input.count) }
        guard let (out, ended, consumed) = stream.decode(input, limit: expectedSize - produced, cap: cap) else {
            throw SheetError.corruptedContainer(detail: "inflate failed")
        }
        produced += out.count
        if ended || produced == expectedSize { finished = true }
        return (out, consumed)
    }

    /// `decode(_:upTo:)` with no cap of its own: everything the input expands to, all of it consumed.
    package func decode(_ input: UnsafeRawBufferPointer) throws -> Data { try decode(input, upTo: Int.max).out }

    /// Asks for whatever the decoder still holds once the compressed bytes are exhausted, at most `cap` of it.
    package func drain(upTo cap: Int = Int.max) throws -> Data { try decode(UnsafeRawBufferPointer(start: nil, count: 0), upTo: cap).out }

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

        /// Expands `input` into at most `bound = min(limit, cap)` bytes. The third value is how much of `input` was
        /// consumed: all of it unless the bound stopped the expansion first.
        func decode(_ input: UnsafeRawBufferPointer, limit: Int, cap: Int) -> (Data, Bool, Int)? {
            guard live else { return (Data(), true, input.count) }
            let bound = Swift.min(limit, cap)
            var out = Data(capacity: Swift.min(bound, DeflateDecoder.pieceCap))
            var ended = false
            raw.pointee.src_ptr = input.isEmpty ? UnsafePointer<UInt8>(bitPattern: 1)! : input.bindMemory(to: UInt8.self).baseAddress!
            raw.pointee.src_size = input.count
            var failed = false
            repeat {
                let room = Swift.min(buffer.count, bound - out.count)
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
                // keep turning while the decoder still has input, or filled the whole room (there may be more) —
                // until the bound, where the rest of the input waits for the next call
            } while raw.pointee.src_size > 0 || out.count < bound && raw.pointee.dst_size == 0
            let consumed = input.count - raw.pointee.src_size
            if ended { compression_stream_destroy(raw); live = false }
            return (out, ended, consumed)
        }
    }
}

#elseif os(WASI)

/// The pure Swift route — WebAssembly carries neither Apple's framework nor zlib. Reading is a complete RFC 1951
/// inflater (fixed and dynamic Huffman blocks); writing folds nothing: stored blocks, which every reader accepts
/// as DEFLATE. Big files, not small ones, is the trade — a browser opening a plan does not mind.
enum Backend {
    static func inflate(_ s: UnsafeRawBufferPointer, expectedSize: Int) -> Data? {
        var inf = Inflater(input: s)
        // one byte of room past the declared size, like the other routes: more than declared is refused, not cut
        guard let out = try? inf.run(limit: expectedSize + 1), inf.ended, out.count == expectedSize else { return nil }
        return out
    }

    static func deflate(_ src: Data) -> Data? { stored(src, final: true) }

    /// `src` as stored blocks of at most 65 535 bytes; `final` sets BFINAL on the last of them.
    static func stored(_ src: Data, final: Bool) -> Data {
        var out = Data(capacity: src.count + src.count / 65535 * 5 + 5)
        if src.isEmpty { if final { out.append(contentsOf: [1, 0, 0, 0xFF, 0xFF]) }; return out }
        var offset = 0
        while offset < src.count {
            let n = Swift.min(65535, src.count - offset)
            let last = final && offset + n == src.count
            out.append(last ? 1 : 0)
            out.append(contentsOf: [UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)])
            out.append(src[src.startIndex + offset ..< src.startIndex + offset + n])
            offset += n
        }
        return out
    }

    final class Stream {
        private var live = true
        init?() {}
        func encode(_ data: Data) -> Data? { live ? Backend.stored(data, final: false) : nil }
        func finish() -> Data? { defer { live = false }; return Data([1, 0, 0, 0xFF, 0xFF]) }
    }

    /// Pieces are gathered and the whole is expanded once it is complete — a stream fed in pieces is inflated
    /// from its start each time more arrives, which costs time on a very large entry and nothing on a plan.
    final class InflateStream {
        private var pending = Data()   // compressed bytes not yet expanded
        private var ready = Data()     // expanded bytes not yet handed out
        private var done = false
        init?() {}

        func decode(_ input: UnsafeRawBufferPointer, limit: Int, cap: Int) -> (Data, Bool, Int)? {
            if !done {
                if !input.isEmpty { pending.append(contentsOf: input) }
                let attempt: Data?? = pending.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Data?? in
                    var inf = Inflater(input: p)
                    do { return .some(try inf.run(limit: Int.max)) }          // complete
                    catch InflateError.needMoreInput { return .some(nil) }     // not yet
                    catch { return .none }                                     // corrupt
                }
                switch attempt {
                case .none: return nil
                case .some(nil): return input.isEmpty ? nil : (Data(), false, input.count)   // finishing with no end is corrupt
                case .some(let out?): ready = out; pending = Data(); done = true
                }
            }
            let n = Swift.min(Swift.min(limit, cap), ready.count)
            let out = Data(ready.prefix(n))
            ready.removeFirst(n)
            return (out, done && ready.isEmpty, input.count)
        }
    }
}

enum InflateError: Error { case needMoreInput, corrupt, tooLarge }

/// RFC 1951, the way zlib's `puff` does it: canonical Huffman tables walked a bit at a time.
struct Inflater {
    private let input: UnsafeRawBufferPointer
    private var pos = 0
    private var bitBuf = 0
    private var bitCnt = 0
    private(set) var ended = false

    init(input: UnsafeRawBufferPointer) { self.input = input }

    private mutating func bits(_ n: Int) throws -> Int {
        var v = bitBuf
        while bitCnt < n {
            guard pos < input.count else { throw InflateError.needMoreInput }
            v |= Int(input[pos]) << bitCnt
            pos += 1
            bitCnt += 8
        }
        bitBuf = v >> n
        bitCnt -= n
        return v & ((1 << n) - 1)
    }

    private struct Huffman {
        var count = [Int](repeating: 0, count: 16)
        var symbol: [Int]
        /// Nil when the lengths describe an over-subscribed set (an incomplete one is allowed, as in puff).
        init?(lengths: [Int]) {
            symbol = [Int](repeating: 0, count: lengths.count)
            for l in lengths { count[l] += 1 }
            if count[0] == lengths.count { return }
            var left = 1
            for len in 1...15 { left <<= 1; left -= count[len]; if left < 0 { return nil } }
            var offs = [Int](repeating: 0, count: 16)
            for len in 1..<15 { offs[len + 1] = offs[len] + count[len] }
            for (sym, l) in lengths.enumerated() where l != 0 { symbol[offs[l]] = sym; offs[l] += 1 }
        }
    }

    private mutating func decode(_ h: Huffman) throws -> Int {
        var code = 0, first = 0, index = 0
        for len in 1...15 {
            code |= try bits(1)
            let count = h.count[len]
            if code - count < first { return h.symbol[index + (code - first)] }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw InflateError.corrupt
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    private static let fixed: (Huffman, Huffman) = {
        var l = [Int](repeating: 8, count: 288)
        for i in 144..<256 { l[i] = 9 }
        for i in 256..<280 { l[i] = 7 }
        return (Huffman(lengths: l)!, Huffman(lengths: [Int](repeating: 5, count: 30))!)
    }()

    /// Expands until the final block, or until `limit` bytes would be exceeded (an error: the entry lied).
    mutating func run(limit: Int) throws -> Data {
        var out = [UInt8]()
        out.reserveCapacity(Swift.min(limit, 1 << 20))
        while !ended {
            let last = try bits(1)
            switch try bits(2) {
            case 0:
                bitBuf = 0; bitCnt = 0   // stored: the rest of this byte is discarded
                guard pos + 4 <= input.count else { throw InflateError.needMoreInput }
                let len = Int(input[pos]) | Int(input[pos + 1]) << 8
                let nlen = Int(input[pos + 2]) | Int(input[pos + 3]) << 8
                guard len == (~nlen & 0xFFFF) else { throw InflateError.corrupt }
                pos += 4
                guard pos + len <= input.count else { throw InflateError.needMoreInput }
                guard out.count + len <= limit else { throw InflateError.tooLarge }
                out.append(contentsOf: UnsafeRawBufferPointer(rebasing: input[pos ..< pos + len]))
                pos += len
            case 1:
                try codes(Inflater.fixed.0, Inflater.fixed.1, into: &out, limit: limit)
            case 2:
                let (lit, dist) = try dynamicTables()
                try codes(lit, dist, into: &out, limit: limit)
            default:
                throw InflateError.corrupt
            }
            if last == 1 { ended = true }
        }
        return Data(out)
    }

    private static let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    private mutating func dynamicTables() throws -> (Huffman, Huffman) {
        let nlen = try bits(5) + 257, ndist = try bits(5) + 1, ncode = try bits(4) + 4
        guard nlen <= 286, ndist <= 30 else { throw InflateError.corrupt }
        var lengths = [Int](repeating: 0, count: 19)
        for i in 0..<ncode { lengths[Inflater.order[i]] = try bits(3) }
        guard let lencode = Huffman(lengths: lengths) else { throw InflateError.corrupt }
        var all = [Int](repeating: 0, count: nlen + ndist)
        var i = 0
        while i < nlen + ndist {
            let sym = try decode(lencode)
            if sym < 16 { all[i] = sym; i += 1; continue }
            var rep = 0, value = 0
            switch sym {
            case 16: guard i > 0 else { throw InflateError.corrupt }; value = all[i - 1]; rep = 3 + (try bits(2))
            case 17: rep = 3 + (try bits(3))
            default: rep = 11 + (try bits(7))
            }
            guard i + rep <= nlen + ndist else { throw InflateError.corrupt }
            for _ in 0..<rep { all[i] = value; i += 1 }
        }
        guard all[256] != 0, let lit = Huffman(lengths: Array(all[0..<nlen])),
              let dist = Huffman(lengths: Array(all[nlen...])) else { throw InflateError.corrupt }
        return (lit, dist)
    }

    private mutating func codes(_ lit: Huffman, _ dist: Huffman, into out: inout [UInt8], limit: Int) throws {
        while true {
            let sym = try decode(lit)
            if sym < 256 {
                guard out.count < limit else { throw InflateError.tooLarge }
                out.append(UInt8(sym))
            } else if sym == 256 {
                return
            } else {
                let li = sym - 257
                guard li < 29 else { throw InflateError.corrupt }
                let len = Inflater.lengthBase[li] + (try bits(Inflater.lengthExtra[li]))
                let di = try decode(dist)
                guard di < 30 else { throw InflateError.corrupt }
                let d = Inflater.distBase[di] + (try bits(Inflater.distExtra[di]))
                guard d <= out.count else { throw InflateError.corrupt }
                guard out.count + len <= limit else { throw InflateError.tooLarge }
                let from = out.count - d
                for k in 0..<len { out.append(out[from + k]) }
            }
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

        /// Expands `input` into at most `bound = min(limit, cap)` bytes. The third value is how much of `input` was
        /// consumed: all of it unless the bound stopped the expansion first.
        func decode(_ input: UnsafeRawBufferPointer, limit: Int, cap: Int) -> (Data, Bool, Int)? {
            guard live else { return (Data(), true, input.count) }
            guard input.count <= Int(UInt32.max) else { return nil }
            let bound = Swift.min(limit, cap)
            var out = Data(capacity: Swift.min(bound, DeflateDecoder.pieceCap))
            var ended = false
            var failed = false
            z.next_in = input.isEmpty ? nil : UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress!)
            z.avail_in = uInt(input.count)
            repeat {
                let room = Swift.min(buffer.count, bound - out.count)
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
            } while z.avail_in > 0 || (out.count < bound && z.avail_out == 0)
            let consumed = input.count - Int(z.avail_in)
            if ended { inflateEnd(&z); live = false }
            return (out, ended, consumed)
        }
    }
}

#endif
