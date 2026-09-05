import Foundation
import SheetCore

/// `StreamingReader` over every format the library ships: `CodecSet.all.streamingReader(…)` under the names this
/// product has always had (spec Appendix B.40 / B.44). The reader itself is declared in `SheetCore`.
extension StreamingReader {
    /// Reads the file through positioned reads rather than mapping it, so a workbook far larger than memory can be
    /// walked and only the pieces in hand are ever in memory (spec Appendix B.39.8, Rev 4.31). The format is
    /// detected from the bytes, as `Workbook(contentsOf:)` does; a Numbers document saved as a folder is opened as
    /// one. `limits` is what the container may declare about itself before it is refused (`ReadOptions.limits`);
    /// `csv` is the dialect and encoding of a text file. A protected XLSX or ODS is refused by name — the
    /// SheetDecrypt product adds `StreamingReader(contentsOf:password:)`.
    public init(contentsOf url: URL, limits: ZipLimits = ZipLimits(), csv: CSVReadOptions = CSVReadOptions()) throws {
        self = try CodecSet.all.streamingReader(contentsOf: url, limits: limits, csv: csv)
    }

    /// Reads from bytes. `format` overrides detection; `filename` only breaks ties for plain text (`.tsv`).
    public init(data: Data, format: SheetFormat? = nil, limits: ZipLimits = ZipLimits(),
                csv: CSVReadOptions = CSVReadOptions(), filename: String? = nil) throws {
        self = try CodecSet.all.streamingReader(data: data, format: format, limits: limits, csv: csv, filename: filename)
    }
}
