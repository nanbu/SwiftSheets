import Foundation

/// Measurement conversions (openpyxl.utils.units): twips (dxa), points, inches, centimetres, EMUs, pixels, angles.
package enum Units {
    package static let defaultRowHeight = 15.0      // points
    package static let baseColumnWidth = 8          // characters
    package static let defaultColumnWidth = 13      // baseColumnWidth + 5

    package static func inchToDxa(_ v: Double) -> Int { Int(v * 20 * 72) }
    package static func dxaToInch(_ v: Double) -> Double { v / 72 / 20 }
    package static func dxaToCm(_ v: Double) -> Double { 2.54 * dxaToInch(v) }
    package static func cmToDxa(_ v: Double) -> Int { inchToDxa(emuToInch(Double(cmToEMU(v)))) }
    package static func pixelsToEMU(_ v: Double) -> Int { Int(v * 9525) }
    package static func emuToPixels(_ v: Double) -> Int { Int((v / 9525).rounded(.toNearestOrEven)) }
    package static func cmToEMU(_ v: Double) -> Int { Int(v * 360_000) }
    package static func emuToCm(_ v: Double) -> Double { (v / 360_000 * 10_000).rounded(.toNearestOrEven) / 10_000 }
    package static func inchToEMU(_ v: Double) -> Int { Int(v * 914_400) }
    package static func emuToInch(_ v: Double) -> Double { (v / 914_400 * 10_000).rounded(.toNearestOrEven) / 10_000 }
    package static func pixelsToPoints(_ v: Double, dpi: Double = 96) -> Double { v * 72 / dpi }
    package static func pointsToPixels(_ v: Double, dpi: Double = 96) -> Int { Int((v * dpi / 72).rounded(.up)) }
    package static func degreesToAngle(_ v: Double) -> Int { Int((v * 60_000).rounded(.toNearestOrEven)) }
    package static func angleToDegrees(_ v: Double) -> Double { (v / 60_000 * 100).rounded(.toNearestOrEven) / 100 }
    /// "FFFF0000" → "FF0000" (drops the alpha byte of an ARGB string).
    package static func shortColor(_ color: String) -> String { color.count > 6 ? String(color.dropFirst(2)) : color }
}
