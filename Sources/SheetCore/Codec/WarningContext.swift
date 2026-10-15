import Foundation

extension ConversionWarning {
    /// A stable cause identifier. Match this value instead of parsing the warning's English message.
    /// Raw values allow new causes without adding cases to a caller's exhaustive switch.
    public struct Code: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public var description: String { rawValue }

        public static let drawingUnreadable = Code(rawValue: "drawing.unreadable")
        public static let drawingUnmodelled = Code(rawValue: "drawing.unmodelled")
        public static let drawingRebuilt = Code(rawValue: "drawing.rebuilt")
        public static let drawingSimplified = Code(rawValue: "drawing.simplified")
        public static let dynamicArrayMetadata = Code(rawValue: "formulas.dynamicArrayMetadata")
    }

    /// Whether the source feature survives this operation, independently of its model or display fidelity.
    public enum Preservation: Hashable, Sendable {
        /// The source feature is retained, even if it is not exposed by the editable model.
        case preserved
        /// Some of the source feature is retained.
        case partial
        /// The source feature is absent from the result.
        case notPreserved
    }

    /// Additional location and outcome information (spec Appendix B.112).
    /// `sheet` and the cell `location` stay on the warning itself.
    public struct Context: Hashable, Sendable {
        public let code: Code
        /// The package entry, when applicable. This is a package-relative path, not a filesystem path.
        public let part: String?
        /// An object name or source identifier, when known.
        public let object: String?
        /// Nil means no assertion was made about preservation.
        public let preservation: Preservation?

        public init(code: Code, part: String? = nil, object: String? = nil, preservation: Preservation? = nil) {
            self.code = code; self.part = part; self.object = object; self.preservation = preservation
        }
    }
}
