import Foundation
import SheetCore

/// `StreamingWriter` for every format the library ships: `CodecSet.all.streamingWriter(…)` under the name this
/// product has always had (spec Appendix B.42 / B.44). The writer itself is declared in `SheetCore`.
extension StreamingWriter {
    /// Starts a file whose first sheet is `sheetName`. `format` overrides the extension; a path with neither is
    /// written as XLSX. `epoch` is the date origin for XLSX and Numbers; `csv` the dialect and encoding of a text
    /// file.
    public convenience init(url: URL, format: SheetFormat? = nil, sheetName: String = "Sheet1", epoch: DateEpoch = .windows1900,
                            csv: CSVWriteOptions = CSVWriteOptions()) throws {
        // the set opens the file and wraps the format's writer; this initialiser is that wrapper under the old name
        let made = try CodecSet.all.streamingWriter(url: url, format: format, sheetName: sheetName, epoch: epoch, csv: csv)
        self.init(sink: made.sink, format: made.format)
    }
}
