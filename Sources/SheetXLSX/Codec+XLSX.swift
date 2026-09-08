import SheetCore

extension Codec {
    /// Excel's workbook (spec §7, Appendix B.50).
    public static let xlsx = Codec(XLSXCodec.self)
    /// The same workbook with macros kept (spec §7.4).
    public static let xlsm = Codec(XLSMCodec.self)
}
