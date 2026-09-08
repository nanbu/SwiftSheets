import SheetCore

extension Codec {
    /// Apple's Numbers document (spec §9, Appendix B.50).
    public static let numbers = Codec(NumbersCodec.self)
}
