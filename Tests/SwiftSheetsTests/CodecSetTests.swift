import Foundation
import Testing
import SwiftSheets

/// The umbrella is a codec set with every codec in it, and its conveniences are that set's methods (spec Appendix B.44).
@Suite struct CodecSetTests {
    static func sample() -> Workbook {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        wb.sheets[0]["B2"] = 42
        return wb
    }

    /// Every format detection can name has a codec in the umbrella's set — the contract the conveniences rest on.
    @Test func theUmbrellaSetHoldsEveryFormat() {
        #expect(Set(CodecSet.all.formats) == Set(SheetFormat.allCases))
        for format in SheetFormat.allCases { #expect(CodecSet.all.contains(format)) }
    }

    /// `Workbook.inspect` / `Workbook.read` and the set's own methods are one path, not two.
    @Test func theConveniencesAreTheFullSet() throws {
        let data = try Self.sample().write(as: .xlsx).data
        let viaWorkbook = try Workbook.inspect(data)
        let viaSet = try CodecSet.all.inspect(data)
        #expect(viaWorkbook == viaSet)
        #expect(try Workbook.read(data).workbook.sheets[0]["B2"] == CodecSet.all.read(data).workbook.sheets[0]["B2"])
        let reader = try StreamingReader(data: data)
        let fromSet = try CodecSet.all.streamingReader(data: data)
        #expect(reader.format == .xlsx && fromSet.format == .xlsx && reader.sheetNames == fromSet.sheetNames)
    }

    /// A set without a format refuses a file of that format by name; the same bytes open through the full set.
    @Test func aFormatOutsideASetIsRefusedByName() throws {
        let ods = try Self.sample().write(as: .ods).data
        let xlsxOnly = CodecSet([.xlsx])
        #expect(xlsxOnly.formats == [.xlsx] && !xlsxOnly.contains(.ods))
        do {
            _ = try xlsxOnly.read(ods)
            Issue.record("an ODS must not open through a set that has no ODS codec")
        } catch {
            let text = String(describing: error)
            #expect(text.contains(".ods") && text.contains("SheetODS"), Comment(rawValue: text))
        }
        #expect(try CodecSet.all.read(ods).workbook.sheets[0]["A1"] == .text("x"))
        // naming a codec twice is one entry, and the order of naming is the order of `formats`
        #expect(CodecSet([.ods, .xlsx, .ods]).formats == [.ods, .xlsx])
    }

    /// A format is chosen by the value its product publishes, and the set answers with that choice — a `Codec`
    /// that says which format it is for and nothing else (spec Appendix B.50).
    @Test func aCodecValueNamesItsFormatAndTheSetHandsItBack() throws {
        #expect([Codec.xlsx.format, Codec.xlsm.format, Codec.ods.format, Codec.numbers.format, Codec.csv.format]
                == [.xlsx, .xlsm, .ods, .numbers, .csv])
        for format in SheetFormat.allCases {
            #expect(try CodecSet.all.codec(for: format).format == format)
        }
        // a set may hold nothing at all: it opens nothing, and says so the same way
        let empty = CodecSet([])
        #expect(empty.formats.isEmpty && !empty.contains(.xlsx))
        do {
            _ = try empty.codec(for: .xlsx)
            Issue.record("an empty set has no codec to hand out")
        } catch {
            let text = String(describing: error)
            #expect(text.contains(".xlsx") && text.contains("SheetXLSX"), Comment(rawValue: text))
        }
    }
}
