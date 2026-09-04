import Foundation

/// What the library calls itself in the files it writes. One constant so that `docProps/app.xml`, ODS's
/// `meta:generator` and the README cannot drift apart — a test checks that last one.
public enum SwiftSheetsInfo: Sendable {
    public static let name = "SwiftSheets"
    /// The released version. Bumped in the release commit itself, so this constant, the README's status line,
    /// the README's `from:` and the git tag always name the same thing — `APIContractTests` checks the first three.
    public static let version = "0.16.1"
    /// "SwiftSheets/0.6.0" — ODF's `meta:generator`.
    public static var generator: String { "\(name)/\(version)" }
    /// OOXML's `AppVersion` takes `major.minor` and nothing more.
    public static var appVersion: String { version.split(separator: ".").prefix(2).joined(separator: ".") }
}
