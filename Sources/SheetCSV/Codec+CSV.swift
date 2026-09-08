import SheetCore

extension Codec {
    /// Delimited text — RFC 4180 and the dialects real files use (spec §4.2, Appendix B.50).
    public static let csv = Codec(CSVCodec.self)
}
