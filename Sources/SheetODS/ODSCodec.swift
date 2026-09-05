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

    public static func canDecode(_ container: ZipInspection) -> Bool { SheetFormat.detect(in: container) == format }

    /// Reading reports what the file held that the model cannot express: data styles with no Excel number-format
    /// form, and rows the cell budget stopped short of.
    public static func read(_ data: Data, options: ReadOptions = ReadOptions()) throws -> ReadResult {
        let (wb, warnings) = try ODSReader.read(data, options: options)
        return ReadResult(workbook: wb, warnings: warnings)
    }

    public static func write(_ workbook: Workbook, options: WriteOptions = WriteOptions()) throws -> WriteResult {
        try ODSWriter.write(workbook, options: options)
    }
}

// MARK: - The rest of the codec contract (spec Appendix B.44)

extension ODSCodec {
    /// ODS keeps every sheet in one part and says nothing about a sheet's size up front, so the content is walked
    /// once as bytes — tables, rows, the cells that carry a value — with the run-length counts multiplied rather
    /// than expanded (spec Appendix B.39.3). A pass over the markup, no model.
    public static func inspect(_ data: Data, options: InspectOptions = InspectOptions()) throws -> WorkbookSummary {
        try ODSInspector.inspect(try ZipArchive(data: data, limits: options.limits), options: options)
    }

    public static func streamingReader(contentsOf url: URL, limits: ZipLimits = ZipLimits(), csv: CSVReadOptions = CSVReadOptions()) throws -> StreamingReader {
        StreamingReader(source: try ODSStreamingReader(contentsOf: url, limits: limits), format: .ods)
    }

    public static func streamingReader(data: Data, limits: ZipLimits = ZipLimits(), csv: CSVReadOptions = CSVReadOptions(), filename: String? = nil) throws -> StreamingReader {
        StreamingReader(source: try ODSStreamingReader(data: data, limits: limits), format: .ods)
    }

    public static func streamingWriter(url: URL, sheetName: String = "Sheet1", epoch: DateEpoch = .windows1900, csv: CSVWriteOptions = CSVWriteOptions()) throws -> StreamingWriter {
        StreamingWriter(sink: try ODSStreamingWriter(url: url, sheetName: sheetName), format: .ods)
    }
}
