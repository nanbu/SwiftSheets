import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Where a file being written row by row actually goes until it is complete: a name reserved in the destination's
/// own directory, renamed over the destination once — and only once — everything has been written (spec Appendix
/// B.51).
///
/// Saving over the file you just opened is this library's whole reason for existing, so a row that fails to
/// serialize, a full disk or a dropped handle must leave the file that was already there exactly as it was. The
/// whole-workbook `write(to:)` has had that since Appendix B.47 (`Data.write(options: .atomic)`); this is the same
/// promise for a writer that hands the format's own writer a file handle and lets it write for an hour.
///
/// **What it promises.** Against the I/O errors these calls return: the destination is either the old file or the
/// new one, never a half-written one. **What it does not.** Durability across a power cut (nothing here calls
/// `fsync`), network file systems, another process replacing the same path at the same time, or carrying the old
/// file's permissions and extended attributes onto the new one.
package final class AtomicFileTarget {
    /// The file the caller asked for. Untouched until `commit()`.
    package let destination: URL
    /// The file to write: reserved beside the destination, on the same file system, so the replace is one rename.
    package let url: URL
    /// Whether the temporary file is still ours to clean up.
    private var reserved = true

    /// The failures a test asks for, in place of the ones only a full disk or a revoked permission would produce
    /// (spec Appendix B.51: each injection point is proved reached rather than hoped for).
    package struct Faults {
        /// Thrown instead of renaming the temporary file over the destination.
        package var commit: (any Error)?
        /// Thrown instead of removing the temporary file.
        package var discard: (any Error)?
        package init() {}
    }
    package var faults = Faults()
    /// The injection points a fault actually fired at, in order.
    package private(set) var firedFaults: [String] = []

    /// Reserves a name beside `destination`. Throws before anything is created when the destination is not a
    /// plain file this library may replace, or when its directory does not exist — no directory is created here.
    package init(destination: URL) throws {
        let reserved = try AtomicFileTarget.reserve(beside: destination)
        self.destination = destination
        self.url = reserved
    }

    private static func reserve(beside destination: URL) throws -> URL {
#if os(WASI)
        // The promise this type makes is a rename over the destination, and nothing here has ever run under a
        // WASI runtime to prove that it holds (spec Appendix B.51). Refusing before anything is created is the
        // honest answer; a non-atomic copy under the same name would not be. Whole-workbook `write(to:as:)`
        // still writes, as it always has on WASI.
        throw SheetError.unsupportedFeature("writing a file row by row saves through a temporary file renamed over the destination, which is unverified on WASI — write the workbook whole with write(to:as:) instead")
#else
        let path = destination.path
        var info = stat()
        // lstat, not stat: a symbolic link is refused as itself rather than followed to what it points at. The
        // POSIX numbers rather than S_IFMT and friends, whose imported Swift type differs between platforms.
        if lstat(path, &info) == 0 {
            switch UInt32(info.st_mode) & 0o170000 {
            case 0o040000:
                throw SheetError.ioFailure(detail: "\(destination.lastPathComponent) is a directory, not a file to write")
            case 0o120000:
                throw SheetError.ioFailure(detail: "\(destination.lastPathComponent) is a symbolic link; writing it would replace the link rather than what it points at")
            default: break
            }
        }
        let parent = destination.deletingLastPathComponent()
        var last: Int32 = 0
        // a hidden name of our own in the destination's directory: the same file system, so the replace is a
        // rename rather than a copy. O_EXCL is what makes the name ours — two writers of the same file get two.
        for _ in 0..<8 {
            let candidate = parent.appendingPathComponent(".\(destination.lastPathComponent).swiftsheets-\(UUID().uuidString)")
            let descriptor = candidate.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o666)) }
            if descriptor >= 0 {
                close(descriptor)   // the format's own writer opens it by name; the mode is umask's to narrow
                return candidate
            }
            last = errno
            if last != EEXIST { break }
        }
        throw SheetError.ioFailure(detail: "cannot write beside \(destination.lastPathComponent) in \(parent.lastPathComponent): \(AtomicFileTarget.reason(last))")
#endif
    }

    /// Replaces the destination with what was written — one rename, and nothing that can fail after it.
    package func commit() throws {
        if let fault = faults.commit { firedFaults.append("commit"); throw fault }
        guard reserved else { return }
#if os(WASI)
        throw SheetError.unsupportedFeature("no atomic replace on WASI")   // unreachable: no target is ever made there
#else
        let renamed = url.path.withCString { from in destination.path.withCString { to in rename(from, to) } }
        guard renamed == 0 else {
            // no unlink-then-move fallback: that is the window this whole file exists to close
            throw SheetError.ioFailure(detail: "cannot replace \(destination.lastPathComponent): \(AtomicFileTarget.reason(errno))")
        }
        reserved = false
#endif
    }

    /// Removes what was written. The destination is not touched. Harmless to call twice.
    package func discard() throws {
        guard reserved else { return }
        if let fault = faults.discard { firedFaults.append("discard"); throw fault }
#if !os(WASI)
        if unlink(url.path) != 0, errno != ENOENT {
            throw SheetError.ioFailure(detail: "cannot remove the unfinished \(url.lastPathComponent): \(AtomicFileTarget.reason(errno))")
        }
#endif
        reserved = false
    }

    /// `discard()` for a `deinit`, which has nowhere to report a failure.
    package func discardQuietly() { try? discard() }

    private static func reason(_ code: Int32) -> String {
#if os(WASI)
        "error \(code)"
#else
        String(cString: strerror(code))
#endif
    }
}
