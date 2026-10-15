extension DrawingTextBody {
    /// Explicit source text margins in EMUs (12,700 per point). An absent side inherits the file format's default.
    public struct Insets: Hashable, Sendable {
        public let left: Int64?
        public let right: Int64?
        public let top: Int64?
        public let bottom: Int64?
    }

    /// Typed access to the source body properties; no extra margins are stored or defaulted.
    public var insets: Insets {
        Insets(left: attributes["lIns"].flatMap(Int64.init), right: attributes["rIns"].flatMap(Int64.init),
               top: attributes["tIns"].flatMap(Int64.init), bottom: attributes["bIns"].flatMap(Int64.init))
    }

    /// Explicit vertical text anchoring. Nil means absent or not represented by the shared alignment vocabulary.
    public var verticalAlignment: Alignment.Vertical? {
        switch attributes["anchor"] {
        case "t": .top
        case "ctr": .center
        case "b": .bottom
        case "just": .justify
        case "dist": .distributed
        default: nil
        }
    }
}

extension DrawingTextBody.Paragraph {
    /// Explicit paragraph alignment; nil leaves inheritance/default resolution to the caller.
    public var alignment: Alignment.Horizontal? {
        switch attributes["algn"] {
        case "l": .left
        case "ctr": .center
        case "r": .right
        case "just": .justify
        case "dist": .distributed
        default: nil
        }
    }
}
