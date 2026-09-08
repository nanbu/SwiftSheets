import SheetCore

extension Codec {
    /// OpenDocument's spreadsheet — LibreOffice's own format (spec §8, Appendix B.50).
    public static let ods = Codec(ODSCodec.self)
}
