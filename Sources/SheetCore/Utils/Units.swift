import Foundation

/// Measurement conversions (openpyxl.utils.units): twips (dxa), points, inches, centimetres, EMUs, pixels, angles.
public enum Units {
    public static let defaultRowHeight = 15.0      // points
    public static let baseColumnWidth = 8          // characters
    public static let defaultColumnWidth = 13      // baseColumnWidth + 5

    public static func inchToDxa(_ v: Double) -> Int { Int(v * 20 * 72) }
    public static func dxaToInch(_ v: Double) -> Double { v / 72 / 20 }
    public static func dxaToCm(_ v: Double) -> Double { 2.54 * dxaToInch(v) }
    public static func cmToDxa(_ v: Double) -> Int { inchToDxa(emuToInch(Double(cmToEMU(v)))) }
    public static func pixelsToEMU(_ v: Double) -> Int { Int(v * 9525) }
    public static func emuToPixels(_ v: Double) -> Int { Int((v / 9525).rounded(.toNearestOrEven)) }
    public static func cmToEMU(_ v: Double) -> Int { Int(v * 360_000) }
    public static func emuToCm(_ v: Double) -> Double { (v / 360_000 * 10_000).rounded(.toNearestOrEven) / 10_000 }
    public static func inchToEMU(_ v: Double) -> Int { Int(v * 914_400) }
    public static func emuToInch(_ v: Double) -> Double { (v / 914_400 * 10_000).rounded(.toNearestOrEven) / 10_000 }
    public static func pixelsToPoints(_ v: Double, dpi: Double = 96) -> Double { v * 72 / dpi }
    public static func pointsToPixels(_ v: Double, dpi: Double = 96) -> Int { Int((v * dpi / 72).rounded(.up)) }
    public static func degreesToAngle(_ v: Double) -> Int { Int((v * 60_000).rounded(.toNearestOrEven)) }
    public static func angleToDegrees(_ v: Double) -> Double { (v / 60_000 * 100).rounded(.toNearestOrEven) / 100 }
    /// "FFFF0000" → "FF0000" (drops the alpha byte of an ARGB string).
    public static func shortColor(_ color: String) -> String { color.count > 6 ? String(color.dropFirst(2)) : color }
}
