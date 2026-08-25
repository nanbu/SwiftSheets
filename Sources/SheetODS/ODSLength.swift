import Foundation

/// ODF lengths ("3.916cm", "12mm", "0.5in", "15pt", "20px", "1pc") ⇄ the model's units (column widths in characters,
/// row heights in points).
enum ODSLength {
    /// Column width conversion (Appendix B.8): **2.0 mm per character**, used identically in both directions so a
    /// width survives an ODS round trip unchanged. (LibreOffice's default column is 2.267 cm for Excel's 8.43
    /// characters — about 2.7 mm per character — but a single agreed constant matters more than matching one
    /// application's default font metrics.)
    static let millimetresPerCharacter = 2.0

    /// Parses an ODF length into millimetres; nil for text that is not a length.
    static func millimetres(_ text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [("cm", 10), ("mm", 1), ("in", 25.4), ("pt", 25.4 / 72), ("pc", 25.4 / 6), ("px", 25.4 / 96)]
        for (unit, factor) in units where s.hasSuffix(unit) {
            guard let v = Double(s.dropLast(unit.count).trimmingCharacters(in: .whitespaces)) else { return nil }
            return v * factor
        }
        return Double(s)   // unit-less: assume millimetres
    }

    static func points(_ text: String) -> Double? { millimetres(text).map { $0 / 25.4 * 72 } }

    static func characters(_ text: String) -> Double? { millimetres(text).map { round($0 / millimetresPerCharacter * 100) / 100 } }

    /// "1.686cm" — three decimals in centimetres, as LibreOffice writes.
    static func cm(millimetres mm: Double) -> String { String(format: "%.3fcm", mm / 10) }
    static func cm(characters: Double) -> String { cm(millimetres: characters * millimetresPerCharacter) }
    /// "1.686cm" from a value already in centimetres.
    static func cmValue(_ centimetres: Double) -> String { String(format: "%.3fcm", centimetres) }
    /// The inverse of `cmValue` / `cm(millimetres:)` in inches, for print margins.
    static func inches(_ text: String) -> Double? { millimetres(text).map { ($0 / 25.4 * 1e6).rounded() / 1e6 } }
    static func pt(_ points: Double) -> String {
        let r = (points * 100).rounded() / 100
        return (r == r.rounded() ? String(Int(r)) : String(r)) + "pt"
    }
}
