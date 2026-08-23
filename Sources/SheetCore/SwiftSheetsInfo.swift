import Foundation

/// What the library calls itself in the files it writes. One constant so that `docProps/app.xml`, ODS's
/// `meta:generator` and the README cannot drift apart — a test checks that last one.
public enum SwiftSheetsInfo: Sendable {
    public static let name = "SwiftSheets"
    /// The version this source tree is working towards (SemVer; the released tags are behind it while work is in flight).
    public static let version = "0.4.0"
    /// "SwiftSheets/0.4.0" — ODF's `meta:generator`.
    public static var generator: String { "\(name)/\(version)" }
    /// OOXML's `AppVersion` takes `major.minor` and nothing more.
    public static var appVersion: String { version.split(separator: ".").prefix(2).joined(separator: ".") }
}
