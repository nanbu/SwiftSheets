import Foundation
import Testing
@testable import SheetCore
@testable import SheetODS
import SwiftSheets

/// Pictures written into ODS (spec Appendix B.43): the part under `Pictures/`, the manifest entry with its media
/// type, the frame in the anchor cell with its size in centimetres — and LibreOffice as the judge of whether all
/// of it reads.
@Suite struct ODSImageTests {
    static let tmp: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("swiftsheets-ods-images")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static func image(_ name: String) throws -> SheetImage { try ImageTests.image(name) }
    static func part(_ name: String, of data: Data) throws -> String {
        String(decoding: try #require(try ZipInspection(data: data).entry(named: name)), as: UTF8.self)
    }
    /// Each `draw:frame` element in a part, opening tag to closing tag.
    static func frames(in xml: String) -> [Substring] {
        xml.split(separator: "<draw:frame", omittingEmptySubsequences: true).dropFirst().compactMap { piece in
            piece.range(of: "</draw:frame>").map { piece[..<$0.lowerBound] }
        }
    }
    /// The number in `svg:width="1.234cm"`-style attributes.
    static func cm(_ attribute: String, in frame: Substring) -> Double? {
        guard let r = frame.range(of: " " + attribute + "=\"") else { return nil }
        let rest = frame[r.upperBound...]
        guard let end = rest.firstIndex(of: "c") else { return nil }
        return Double(rest[..<end])
    }
    static func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.0015 } ?? false }

    /// The part is the caller's bytes, the manifest names it with its media type, and the frame sits in the cell —
    /// which is written for it, row and all, though nothing else is there. And the writer no longer counts a loss.
    @Test func thePictureBecomesAPartAndAFrameInItsCell() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        let png = try Self.image("tiny.png")
        wb.sheets[0].addImage(png, at: "B2")
        let url = Self.tmp.appendingPathComponent("one.ods")
        let result = try wb.write(to: url, as: .ods)
        #expect(!result.warnings.contains { $0.message.contains("image") }, Comment(rawValue: "\(result.warnings.map(\.message))"))
        let data = try Data(contentsOf: url)
        #expect(try ZipInspection(data: data).entry(named: "Pictures/image1.png") == png.data, "the part is the caller's bytes, untouched")
        #expect(try Self.part("META-INF/manifest.xml", of: data)
            .contains("<manifest:file-entry manifest:full-path=\"Pictures/image1.png\" manifest:media-type=\"image/png\"/>"))
        let content = try Self.part("content.xml", of: data)
        let frames = Self.frames(in: content)
        #expect(frames.count == 1)
        #expect(content.contains("<table:table-row><table:table-cell/><table:table-cell><draw:frame draw:z-index=\"0\" draw:name=\"Image 1\""),
                "row 2 is written with an empty A2 and the frame's cell at B2")
        #expect(content.contains("<draw:image xlink:href=\"Pictures/image1.png\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\" draw:mime-type=\"image/png\"/></draw:frame></table:table-cell>"))
        // 6 × 4 pixels at 96 dpi
        #expect(Self.close(Self.cm("svg:width", in: frames[0]), 6 * 2.54 / 96))
        #expect(Self.close(Self.cm("svg:height", in: frames[0]), 4 * 2.54 / 96))
        #expect(frames[0].contains(" svg:x=\"0cm\" svg:y=\"0cm\""))
        #expect(!frames[0].contains("end-cell-address"), "a picture at one cell has no end")
    }

    /// The three sizings of Appendix B.32 in centimetres: the pixel size, the size the caller chose, and the
    /// largest that fits the cell as the sheet describes it now.
    @Test func theSizesAreCentimetresAt96DPI() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        wb.sheets[0].addImage(try Self.image("tiny.png"), at: "C1", sizing: .scaled(width: 96, height: 48))
        wb.sheets[0].setWidth(6, ofColumn: "D")     // 47 px
        wb.sheets[0].setHeight(24, ofRow: 0)        // 32 px
        wb.sheets[0].addImage(try Self.image("tiny.jpg"), at: "D1", sizing: .fitCell)
        let content = try Self.part("content.xml", of: try wb.data(as: .ods))
        let frames = Self.frames(in: content)
        try #require(frames.count == 2)
        #expect(Self.close(Self.cm("svg:width", in: frames[0]), 2.54) && Self.close(Self.cm("svg:height", in: frames[0]), 1.27))
        // 6 × 4 into 47 × 32: the width is the limit, 47 × 31.33 px
        #expect(Self.close(Self.cm("svg:width", in: frames[1]), 47 * 2.54 / 96))
        #expect(Self.close(Self.cm("svg:height", in: frames[1]), 47.0 / 6 * 4 * 2.54 / 96))
        #expect(frames[1].contains("Pictures/image2.jpg") && frames[1].contains("draw:mime-type=\"image/jpeg\""))
    }

    /// A picture over a range sits in the range's first cell and names the cell past its far corner as its end,
    /// with the range's width and height as the sheet describes them (2 mm a character, the row height in points).
    @Test func aPictureOverARangeNamesItsEnd() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        wb.sheets[0].addImage(try Self.image("tiny.gif"), over: "C3:D4")
        let content = try Self.part("content.xml", of: try wb.data(as: .ods))
        let frames = Self.frames(in: content)
        try #require(frames.count == 1)
        #expect(frames[0].contains(" table:end-cell-address=\"Sheet1.E5\" table:end-x=\"0cm\" table:end-y=\"0cm\""))
        #expect(Self.close(Self.cm("svg:width", in: frames[0]), 2 * 8.43 * 2.0 / 10))
        #expect(Self.close(Self.cm("svg:height", in: frames[0]), 2 * 15 * 2.54 / 72))
        // the anchor cell is C3: row 3 holds two empty cells and then the frame
        #expect(content.contains("<table:table-row><table:table-cell table:number-columns-repeated=\"2\"/><table:table-cell><draw:frame"))
    }

    /// A picture anchored inside a merge is written in the merge's first cell — a covered cell holds nothing —
    /// and is neither lost nor left in a cell the reader skips.
    @Test func aPictureInsideAMergeMovesToTheMergesFirstCell() throws {
        var wb = Workbook()
        wb.sheets[0]["B2"] = "merged"
        wb.sheets[0].merge("B2:C3")
        wb.sheets[0].addImage(try Self.image("tiny.png"), at: "C3")
        wb.sheets[0].addImage(try Self.image("tiny.gif"), over: "C3:D4")
        let content = try Self.part("content.xml", of: try wb.data(as: .ods))
        let frames = Self.frames(in: content)
        try #require(frames.count == 2)
        #expect(content.contains("table:number-columns-spanned=\"2\" table:number-rows-spanned=\"2\" office:value-type=\"string\"><draw:frame draw:z-index=\"0\""),
                "both frames sit in B2's element, before its text")
        #expect(frames[1].contains(" table:end-cell-address=\"Sheet1.E5\""), "the span keeps its own end")
        #expect(!content.contains("<table:covered-table-cell><draw:frame"))
    }

    /// Two pictures at one cell stack in the order they were added, each its own part.
    @Test func twoPicturesInOneCellStack() throws {
        var wb = Workbook()
        wb.sheets[0].addImage(try Self.image("tiny.png"), at: "B2")
        wb.sheets[0].addImage(try Self.image("tiny.gif"), at: "B2")
        let data = try wb.data(as: .ods)
        let frames = Self.frames(in: try Self.part("content.xml", of: data))
        try #require(frames.count == 2)
        #expect(frames[0].hasPrefix(" draw:z-index=\"0\" draw:name=\"Image 1\"") && frames[0].contains("Pictures/image1.png"))
        #expect(frames[1].hasPrefix(" draw:z-index=\"1\" draw:name=\"Image 2\"") && frames[1].contains("Pictures/image2.gif"))
        let names = try ZipInspection(data: data).entryNames.filter { $0.hasPrefix("Pictures/") }
        #expect(names == ["Pictures/image1.png", "Pictures/image2.gif"])
    }

    /// A source ODS brings its own `Pictures/` along (unlinked, as before); a picture added afterwards takes the
    /// next free name, and the manifest lists both.
    @Test func namesStepPastThePartsASourceODSBroughtAlong() throws {
        var first = Workbook()
        first.sheets[0].addImage(try Self.image("tiny.png"), at: "B2")
        var again = try Workbook(data: try first.data(as: .ods))
        #expect(again.preserved.parts.keys.contains("Pictures/image1.png"))
        let gif = try Self.image("tiny.gif")
        again.sheets[0].addImage(gif, at: "C3")
        let url = Self.tmp.appendingPathComponent("again.ods")
        let result = try again.write(to: url, as: .ods)
        #expect(result.warnings.contains { $0.message.contains("not re-linked") })
        let data = try Data(contentsOf: url)
        let zip = try ZipInspection(data: data)
        #expect(zip.entryNames.filter { $0.hasPrefix("Pictures/") } == ["Pictures/image1.png", "Pictures/image2.gif"])
        #expect(zip.entry(named: "Pictures/image2.gif") == gif.data)
        let manifest = try Self.part("META-INF/manifest.xml", of: data)
        #expect(manifest.contains("manifest:full-path=\"Pictures/image1.png\"") && manifest.contains("manifest:full-path=\"Pictures/image2.gif\" manifest:media-type=\"image/gif\""))
        #expect(Self.frames(in: try Self.part("content.xml", of: data)).count == 1, "the source picture's frame is not re-linked; the new one is there")
    }

    // MARK: - LibreOffice as the judge

    /// `soffice --headless --convert-to <ext>`; the converted file. Each call gets a profile of its own: two
    /// conversions sharing one would be one LibreOffice instance, and the second request can land on an instance
    /// that is already on its way out.
    static func convert(_ file: URL, to ext: String) throws -> URL {
        let run = tmp.appendingPathComponent("run-\(UUID().uuidString)")
        let outdir = run.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outdir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ODSCodecTests.soffice)
        p.arguments = ["-env:UserInstallation=file://\(run.appendingPathComponent("profile").path)", "--headless", "--convert-to", ext, "--outdir", outdir.path, file.path]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let out = outdir.appendingPathComponent(file.deletingPathExtension().lastPathComponent + "." + ext)
        try #require(FileManager.default.fileExists(atPath: out.path), Comment(rawValue: "LibreOffice did not produce \(out.lastPathComponent): \(log)"))
        return out
    }

    static func twoPictures() throws -> URL {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        wb.sheets[0].addImage(try image("tiny.png"), at: "B2")
        wb.sheets[0].addImage(try image("tiny.gif"), over: "C3:D4")
        let url = tmp.appendingPathComponent("judge-\(UUID().uuidString).ods")
        _ = try wb.write(to: url, as: .ods)
        return url
    }

    /// LibreOffice reads both pictures and carries them into an XLSX: two media parts, two pictures in the drawing.
    @Test(.enabled(if: ODSCodecTests.hasLibreOffice, "LibreOffice is not installed at \(ODSCodecTests.soffice)"))
    func libreOfficeCarriesThePicturesIntoXLSX() throws {
        let xlsx = try Self.convert(try Self.twoPictures(), to: "xlsx")
        let zip = try ZipInspection(data: try Data(contentsOf: xlsx))
        #expect(zip.entryNames.filter { $0.hasPrefix("xl/media/") }.count == 2, Comment(rawValue: zip.entryNames.joined(separator: " ")))
        let drawing = String(decoding: try #require(zip.entry(named: "xl/drawings/drawing1.xml")), as: UTF8.self)
        #expect(drawing.components(separatedBy: "<xdr:pic>").count == 3, "two pictures")
        // the picture over C3:D4 keeps its two corners: LibreOffice honours table:end-cell-address
        #expect(drawing.contains("<xdr:twoCellAnchor"), Comment(rawValue: drawing))
    }

    /// LibreOffice saves the document again with both pictures still in it: the frames, the parts, the manifest.
    @Test(.enabled(if: ODSCodecTests.hasLibreOffice, "LibreOffice is not installed at \(ODSCodecTests.soffice)"))
    func libreOfficeKeepsThePicturesWhenItSavesTheODSAgain() throws {
        let ods = try Self.twoPictures()
        // the converter writes beside the source under the same name, so it gets a copy in its own directory
        let copy = Self.tmp.appendingPathComponent("resave-\(UUID().uuidString)").appendingPathComponent("pictures.ods")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: ods, to: copy)
        let saved = try Self.convert(copy, to: "ods")
        let data = try Data(contentsOf: saved)
        let content = try Self.part("content.xml", of: data)
        #expect(content.components(separatedBy: "<draw:image").count == 3, "two pictures survive the round trip")
        #expect(try ZipInspection(data: data).entryNames.filter { $0.hasPrefix("Pictures/") }.count == 2)
    }
}
