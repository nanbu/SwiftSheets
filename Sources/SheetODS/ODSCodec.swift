import Foundation
import SheetCore

/// ODF 1.3 OpenDocument Spreadsheet (.ods) — spec chapter 8 and Appendix B.8. Implemented from the OASIS ODF
/// specification (Part 3 schema, Part 4 OpenFormula) and validated against LibreOffice's headless converter; no
/// LibreOffice source code was consulted (spec §1.4).
///
/// Reading: `content.xml` (tables, RLE-compressed rows / columns / cells, merges, automatic styles, named
/// expressions), `styles.xml` (named parents, data styles, font faces), `settings.xml` (freeze panes, active
/// sheet), `meta.xml`; every other package entry is kept as an opaque part. Writing: a fresh package with
/// `mimetype` first and stored, automatic styles deduplicated by value, run-length rows and cells, formulas in the
/// OpenFormula dialect with their cached values, notes as `office:annotation`, hyperlinks as `text:a`.
///
/// Numeric conventions: column widths convert at `ODSLength.millimetresPerCharacter` (2.0 mm per character, both
/// directions); row heights are written in points; border widths map thin / medium / thick to 0.75 / 1.75 / 2.5 pt.
public enum ODSCodec: SpreadsheetCodec {
    public static var format: SheetFormat { .ods }

    public static func canDecode(_ container: ZipInspection) -> Bool {
        guard let mime = container.entry(named: "mimetype") else { return false }
        return String(decoding: mime, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "application/vnd.oasis.opendocument.spreadsheet"
    }

    public static func read(_ data: Data, options: ReadOptions = ReadOptions()) throws -> Workbook {
        try readWithWarnings(data, options: options).workbook
    }

    /// `read` plus what the file held that the model cannot express (data styles with no Excel number-format form).
    public static func readWithWarnings(_ data: Data, options: ReadOptions = ReadOptions()) throws -> (workbook: Workbook, warnings: [ConversionWarning]) {
        let (wb, warnings) = try ODSReader.read(data, options: options)
        return (wb, warnings)
    }

    public static func write(_ workbook: Workbook, options: WriteOptions = WriteOptions()) throws -> WriteResult {
        try ODSWriter.write(workbook, options: options)
    }
}
