import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SheetCSV
import SheetODS
import SheetNumbers
import SwiftSheets

/// Pictures placed with `addImage` (spec Appendix B.32): sniffing, sizing, the generated drawing part, splicing
/// into a preserved drawing, and the counted losses in formats that have no place for them.
@Suite struct ImageTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/images")
    static func image(_ name: String) throws -> SheetImage {
        try SheetImage(data: try Data(contentsOf: fixtures.appendingPathComponent(name)))
    }

    /// The same 6×4 picture, once per format: what the bytes say wins, whatever the file was called.
    @Test(arguments: [("tiny.png", SheetImage.Format.png), ("tiny.jpg", .jpeg), ("tiny.gif", .gif)])
    func formatAndSizeComeFromTheBytes(_ name: String, _ format: SheetImage.Format) throws {
        let img = try Self.image(name)
        #expect(img.format == format)
        #expect(img.pixelWidth == 6 && img.pixelHeight == 4)
    }

    /// Unknown leading bytes are refused as unsupported; a recognized header cut short is malformed.
    @Test func badBytesAreRefusedByName() {
        #expect(throws: SheetError.unsupportedFeature("unrecognized image format (PNG, JPEG and GIF are supported)")) {
            _ = try SheetImage(data: Data("not an image at all".utf8))
        }
        #expect(throws: SheetError.malformedPart(path: "image", detail: "PNG too short for IHDR")) {
            _ = try SheetImage(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]))
        }
    }

    /// A fresh workbook gets the full set: media bytes untouched, a drawing part, its rels, the content types,
    /// and the worksheet element — with EMU sizes straight from the pixel size.
    @Test func aFreshWorkbookGrowsAWholeDrawing() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        let img = try Self.image("tiny.png")
        wb.sheets[0].addImage(img, at: "B2")
        let data = try wb.data(as: .xlsx)

        let drawing = try Package.part("xl/drawings/drawing1.xml", of: data)
        #expect(drawing.contains("<xdr:oneCellAnchor"))
        #expect(drawing.contains("<xdr:col>1</xdr:col>") && drawing.contains("<xdr:row>1</xdr:row>"))
        #expect(drawing.contains("cx=\"\(6 * 9525)\" cy=\"\(4 * 9525)\""), "EMU is pixels × 9525")
        #expect(drawing.contains("r:embed=\"rId1\""))
        let rels = try Package.part("xl/drawings/_rels/drawing1.xml.rels", of: data)
        #expect(rels.contains("Target=\"../media/image1.png\""))
        let types = try Package.part("[Content_Types].xml", of: data)
        #expect(types.contains("Extension=\"png\" ContentType=\"image/png\""))
        #expect(types.contains("PartName=\"/xl/drawings/drawing1.xml\""))
        #expect(try Package.part("xl/worksheets/sheet1.xml", of: data).contains("<drawing r:id="))
        #expect(try ZipInspection(data: data).entry(named: "xl/media/image1.png") == img.data, "media bytes are the caller's, untouched")
    }

    /// A span anchor covers the range: both corners follow their cells, the far corner exclusive.
    @Test func aSpanBecomesATwoCellAnchor() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        wb.sheets[0].addImage(try Self.image("tiny.gif"), over: "B2:D6")
        let drawing = try Package.part("xl/drawings/drawing1.xml", of: try wb.data(as: .xlsx))
        #expect(drawing.contains("<xdr:twoCellAnchor"))
        #expect(drawing.contains("<xdr:from><xdr:col>1</xdr:col>"))
        #expect(drawing.contains("<xdr:to><xdr:col>4</xdr:col>"), "the far corner is one past the range")
    }

    /// `.resizeCellToFit` shapes the cell at the moment of the call — the writer never edits the model.
    @Test func resizeCellToFitShapesTheCellNow() throws {
        var wb = Workbook()
        let img = try Self.image("tiny.png")
        wb.sheets[0].addImage(img, at: "B2", sizing: .resizeCellToFit)
        #expect(wb.sheets[0].columnDimensions[1]?.width == CellPixels.columnWidth(forPixels: 6))
        #expect(wb.sheets[0].rowDimensions[1]?.height == CellPixels.rowHeight(forPixels: 4))
    }

    /// The heart of the phase: a sheet that already carries a drawing (a chart) keeps every byte of what was
    /// there — the new anchor is spliced in after it, its relationship numbered after the existing maximum.
    @Test func addingToAChartSheetSplicesAndPreserves() throws {
        let original = try PreservationTests.fixture("charts-and-friends.xlsx")
        var wb = try XLSXCodec.read(original).workbook
        let sourceDrawing = try Package.part("xl/drawings/drawing1.xml", of: original)
        let sourceChart = try Package.part("xl/charts/chart1.xml", of: original)
        let sourceRels = try Package.part("xl/drawings/_rels/drawing1.xml.rels", of: original)

        wb.sheets[0].addImage(try Self.image("tiny.png"), at: "H2")
        let data = try XLSXCodec.write(wb).data

        #expect(try Package.part("xl/charts/chart1.xml", of: data) == sourceChart, "the chart part stays byte for byte")
        let drawing = try Package.part("xl/drawings/drawing1.xml", of: data)
        let sourceBody = sourceDrawing.replacing(#/</[A-Za-z0-9_]*:?wsDr[ \t\r\n]*>/#, with: "")   // the fixture's root is unprefixed
        #expect(drawing.hasPrefix(sourceBody), "everything that was in the drawing is still there, in place")
        #expect(drawing.contains("<xdr:oneCellAnchor"), "and the new anchor follows it")

        let rels = try Package.part("xl/drawings/_rels/drawing1.xml.rels", of: data)
        let sourceMax = sourceRels.matches(of: #/Id="rId([0-9]+)"/#).compactMap { Int($0.1) }.max() ?? 0
        #expect(rels.contains("Id=\"rId\(sourceMax + 1)\""), "the image relationship is numbered after the source's maximum")
        #expect(try Package.part("xl/worksheets/sheet1.xml", of: data).matches(of: #/<drawing /#).count == 1,
                "one drawing element — the schema allows no second")
    }

    /// The B.22 lesson, applied here before it can bite: the second save of a file we drew into. Reading our own
    /// output leaves `images` empty (the drawing is preserved bytes now), so writing again must repack the
    /// drawing, its rels and the media byte for byte — no doubled anchors, no renumbered relationships.
    @Test func theSecondSaveChangesNothing() throws {
        // fresh-drawing path
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        wb.sheets[0].addImage(try Self.image("tiny.png"), at: "B2")
        let first = try wb.data(as: .xlsx)
        let back = try Workbook(data: first)
        #expect(back.sheets[0].images.isEmpty, "our own picture reads back as preserved bytes, not as a model image")
        let second = try back.data(as: .xlsx)
        for part in ["xl/drawings/drawing1.xml", "xl/drawings/_rels/drawing1.xml.rels", "xl/media/image1.png"] {
            #expect(try ZipInspection(data: second).entry(named: part) == ZipInspection(data: first).entry(named: part),
                    "\(part) must survive the second save byte for byte")
        }

        // spliced-into-a-chart path
        var chartWB = try XLSXCodec.read(try PreservationTests.fixture("charts-and-friends.xlsx")).workbook
        chartWB.sheets[0].addImage(try Self.image("tiny.png"), at: "H2")
        let spliced = try XLSXCodec.write(chartWB).data
        let splicedAgain = try XLSXCodec.write(XLSXCodec.read(spliced).workbook).data
        for part in ["xl/drawings/drawing1.xml", "xl/drawings/_rels/drawing1.xml.rels", "xl/charts/chart1.xml"] {
            #expect(try ZipInspection(data: splicedAgain).entry(named: part) == ZipInspection(data: spliced).entry(named: part),
                    "\(part) must survive the second save byte for byte")
        }
    }

    /// The formats that cannot hold a picture say what they lost, counted, never in silence.
    @Test func formatsWithoutPicturesCountTheLoss() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        wb.sheets[0].addImage(try Self.image("tiny.png"), at: "B2")
        wb.sheets[0].addImage(try Self.image("tiny.gif"), over: "C3:D4")
        for format in [SheetFormat.ods, .numbers, .csv] {
            let result = try wb.write(to: URL(filePath: NSTemporaryDirectory() + "img-drop.\(format.rawValue)"), as: format)
            #expect(result.warnings.contains { $0.kind == .dropped && $0.message.contains("2 image(s)") },
                    "\(format.rawValue) must count both images out loud")
        }
    }
}
