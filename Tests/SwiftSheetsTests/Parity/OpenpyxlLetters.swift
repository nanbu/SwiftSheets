import SwiftSheets

/// openpyxl's one-letter `cell.data_type`, for the ported tests that assert it. The library itself has no such
/// letter (spec Appendix B.58) — a caller switches on the `CellValue` case instead.
extension CellValue {
    var openpyxlDataType: Character {
        switch self {
        case .integer, .number: "n"
        case .text, .richText: "s"
        case .bool: "b"
        case .date, .time, .duration: "d"
        case .formula: "f"
        case .error: "e"
        }
    }
}

extension Cell {
    /// "n" for an empty cell, as openpyxl reports it.
    var openpyxlDataType: Character { value?.openpyxlDataType ?? "n" }
}
