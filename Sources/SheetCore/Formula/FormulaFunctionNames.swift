/// The small, evidence-backed part of function-name conversion that belongs at the file-format edge.
///
/// This is deliberately not a function catalogue or evaluator. A row is present only when XLSX and OpenFormula
/// have the same operation under different stored names, or when OOXML requires `_xlfn.` for an OpenFormula
/// standard name. Similar-looking functions with different arguments or error rules do not belong here.
enum FormulaFunctionNames {
    struct Mapping: Hashable, Sendable {
        /// The formula tree uses OOXML's invariant stored spelling as its canonical name.
        let xlsx: String
        let ods: String
    }

    /// Names which are standard OpenFormula functions but belong to OOXML's future-function namespace.
    /// The allow-list is the intersection of ODF 1.3 Part 4 function names and MS-XLSX's
    /// `future-function-list`; `_xlfn.` must never be stripped from an arbitrary Excel function.
    static let openFormulaFutureFunctions = [
        "ACOT", "ACOTH", "ARABIC", "BASE", "BINOM.DIST.RANGE",
        "BITAND", "BITLSHIFT", "BITOR", "BITRSHIFT", "BITXOR",
        "COMBINA", "COT", "COTH", "CSC", "CSCH", "DAYS", "DECIMAL",
        "GAMMA", "GAUSS", "IFNA", "IMCOSH", "IMCOT", "IMCSC", "IMCSCH",
        "IMSECH", "IMSINH", "IMTAN", "ISFORMULA", "ISOWEEKNUM", "MUNIT",
        "NUMBERVALUE", "PDURATION", "PERMUTATIONA", "PHI", "RRI", "SEC",
        "SECH", "SHEET", "SHEETS", "UNICHAR", "UNICODE", "XOR",
    ]

    /// Exact semantic aliases found in the two standards. The eight `LEGACY.` rows are the old Excel
    /// compatibility functions, not the newer dotted statistical family.
    static let mappings: [Mapping] = [
        Mapping(xlsx: "DBCS", ods: "JIS"),
        Mapping(xlsx: "CHIDIST", ods: "LEGACY.CHIDIST"),
        Mapping(xlsx: "CHIINV", ods: "LEGACY.CHIINV"),
        Mapping(xlsx: "CHITEST", ods: "LEGACY.CHITEST"),
        Mapping(xlsx: "FDIST", ods: "LEGACY.FDIST"),
        Mapping(xlsx: "FINV", ods: "LEGACY.FINV"),
        Mapping(xlsx: "NORMSDIST", ods: "LEGACY.NORMSDIST"),
        Mapping(xlsx: "NORMSINV", ods: "LEGACY.NORMSINV"),
        Mapping(xlsx: "TDIST", ods: "LEGACY.TDIST"),
        Mapping(xlsx: "_xlfn.FORMULATEXT", ods: "FORMULA"),
        Mapping(xlsx: "_xlfn.SKEW.P", ods: "SKEWP"),
    ] + openFormulaFutureFunctions.map { Mapping(xlsx: "_xlfn." + $0, ods: $0) }

    private static let byXLSX = Dictionary(uniqueKeysWithValues: mappings.map { ($0.xlsx.uppercased(), $0) })
    private static let byODS = Dictionary(uniqueKeysWithValues: mappings.map { ($0.ods.uppercased(), $0) })

    static func canonical(_ name: String, parsedAs dialect: SheetFormat) -> String {
        let key = name.uppercased()
        if dialect == .ods, let mapping = byODS[key] { return mapping.xlsx }
        if dialect != .ods, let mapping = byXLSX[key] { return mapping.xlsx }

        // Japanese Excel exposes JIS to users although OOXML stores DBCS. LibreOffice also accepts/stores DBCS
        // as a compatibility spelling in ODS. Accept both at the API boundary without generating either anomaly.
        if key == "JIS" || key == "DBCS" { return "DBCS" }
        return defaultCanonical(name)
    }

    static func rendered(_ name: String, as dialect: SheetFormat) -> String {
        let key = name.uppercased()
        let mapping = byXLSX[key] ?? byODS[key]
        guard let mapping else { return name }
        return dialect == .ods ? mapping.ods : mapping.xlsx
    }

    static func hasOpenFormulaName(for name: String) -> Bool {
        byXLSX[name.uppercased()] != nil
    }

    /// Preserve an unknown namespace exactly while upper-casing its local function name, matching the old parser
    /// behaviour. Known names above are returned in the standard's exact spelling.
    private static func defaultCanonical(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return name.uppercased() }
        return String(name[...dot]) + name[name.index(after: dot)...].uppercased()
    }
}
