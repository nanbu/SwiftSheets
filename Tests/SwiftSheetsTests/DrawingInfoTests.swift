import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// The inspection snapshot and exact-anchor contract (B.109), using synthetic source markup only.
struct DrawingInfoTests {
    static func drawing(_ body: String) -> String {
        "<xdr:wsDr xmlns:xdr=\"\(DrawingParts.nsSpreadsheetDrawing)\" xmlns:a=\"\(DrawingParts.nsDrawingMain)\">" + body + "</xdr:wsDr>"
    }
    static func shape(_ body: String = "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>", text: String = "") -> String {
        "<xdr:sp><xdr:nvSpPr><xdr:cNvPr id=\"7\" name=\"Synthetic shape\"/><xdr:cNvSpPr/></xdr:nvSpPr><xdr:spPr>" + body + "</xdr:spPr>" + text + "</xdr:sp>"
    }
    static func oneCell(_ object: String) -> String {
        "<xdr:oneCellAnchor><xdr:from><xdr:col>1</xdr:col><xdr:colOff>31750</xdr:colOff><xdr:row>2</xdr:row><xdr:rowOff>123</xdr:rowOff></xdr:from><xdr:ext cx=\"123457\" cy=\"98765\"/>" + object + "<xdr:clientData/></xdr:oneCellAnchor>"
    }
    static func workbook(_ xml: String) throws -> Workbook {
        var wb = Workbook()
        wb.sheets[0].addShape(Shape(.rectangle), over: "A1:B2")
        wb.sheets[0].rowDimensions[3] = RowDimension(height: 20, hidden: true)
        let zip = try ZipArchive(data: wb.write(as: .xlsx).data)
        let out = ZipWriter()
        for name in zip.names { out.add(name, name == "xl/drawings/drawing1.xml" ? Data(xml.utf8) : try zip.read(name)) }
        return try Workbook(data: out.finish())
    }

    @Test func fractionalSourcePositionSurvivesRebuildingAndUserPlacementWins() throws {
        let xml = Self.drawing(Self.oneCell(Self.shape()))
        var wb = try Self.workbook(xml)
        let anchor = DrawingAnchor.oneCell(from: .init(cell: CellRef("B3")!, columnOffset: 31750, rowOffset: 123), width: 123457, height: 98765)
        #expect(wb.sheets[0].shapes[0].drawingAnchor == anchor)
        #expect(wb.sheets[0].drawingInfo?.objects[0].anchor == anchor)
        #expect(wb.sheets[0].rowDimensions[3]?.hidden == true)
        let same = try wb.write(as: .xlsx)
        #expect(try Package.part("xl/drawings/drawing1.xml", of: same.data) == xml)
        #expect(same.warnings.isEmpty)

        wb.sheets[0].shapes[0].text = "edited"
        let changed = try wb.write(as: .xlsx)
        let rebuiltXML = try Package.part("xl/drawings/drawing1.xml", of: changed.data)
        #expect(rebuiltXML.contains("<xdr:colOff>31750</xdr:colOff>") && rebuiltXML.contains("<xdr:ext cx=\"123457\" cy=\"98765\"/>"))
        #expect(rebuiltXML.contains("<a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"123457\" cy=\"98765\"/></a:xfrm>"), "the shape transform also retains the fractional EMU extent")
        #expect(try Workbook(data: changed.data).sheets[0].shapes[0].drawingAnchor == anchor)
        #expect(changed.warnings.isEmpty)

        wb.sheets[0].shapes[0].anchor = .span(CellRange("E5:F6")!)
        #expect(wb.sheets[0].shapes[0].drawingAnchor == nil)
        let moved = try Workbook(data: wb.write(as: .xlsx).data)
        #expect(moved.sheets[0].shapes[0].anchor == .span(CellRange("E5:F6")!))
        #expect(wb.sheets[0].drawingInfo?.objects[0].anchor == anchor, "inspection remains an as-read snapshot")
    }

    @Test func absoluteAndTwoCellPositionsKeepIntegerPrecisionAndEditBehaviour() throws {
        let absolute = "<xdr:absoluteAnchor><xdr:pos x=\"31750\" y=\"123\"/><xdr:ext cx=\"123457\" cy=\"98765\"/>" + Self.shape() + "<xdr:clientData/></xdr:absoluteAnchor>"
        let span = "<xdr:twoCellAnchor editAs=\"oneCell\"><xdr:from><xdr:col>0</xdr:col><xdr:colOff>17</xdr:colOff><xdr:row>0</xdr:row><xdr:rowOff>19</xdr:rowOff></xdr:from><xdr:to><xdr:col>16384</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>4</xdr:row><xdr:rowOff>23</xdr:rowOff></xdr:to>" + Self.shape() + "<xdr:clientData/></xdr:twoCellAnchor>"
        var wb = try Self.workbook(Self.drawing(absolute + span))
        let anchors = wb.sheets[0].shapes.map(\.drawingAnchor)
        #expect(anchors[0] == .absolute(x: 31750, y: 123, width: 123457, height: 98765))
        if case .twoCell(let from, let to, let editAs)? = anchors[1] {
            #expect(from.cell == CellRef("A1") && from.columnOffset == 17 && to.column == 16384 && to.cell == nil && editAs == "oneCell")
        } else { Issue.record("expected an exact two-cell anchor") }
        wb.sheets[0].shapes[0].name = "rebuild"
        let result = try wb.write(as: .xlsx)
        #expect(try Workbook(data: result.data).sheets[0].shapes.map(\.drawingAnchor) == anchors)
        #expect(try Package.part("xl/drawings/drawing1.xml", of: result.data).contains("editAs=\"oneCell\""))
    }

    @Test func groupsRetainLocalTransformsSourceOrderAndDistinctTextRuns() throws {
        let text = """
        <xdr:txBody><a:bodyPr lIns="31750" rIns="0" anchor="ctr" vert="vert270"/><a:lstStyle/>
          <a:p><a:pPr algn="ctr"/><a:r><a:rPr b="1" sz="1400"><a:solidFill><a:srgbClr val="FF0000"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="游明朝"/></a:rPr><a:t>日本語</a:t></a:r><a:br/><a:r><a:rPr i="1"><a:solidFill><a:schemeClr val="accent1"/></a:solidFill></a:rPr><a:t>blue</a:t></a:r></a:p>
          <a:p><a:pPr algn="r"/><a:r><a:t>second</a:t></a:r></a:p>
        </xdr:txBody>
        """
        let child = Self.shape("<a:xfrm rot=\"1800000\" flipH=\"1\"><a:off x=\"100\" y=\"200\"/><a:ext cx=\"300\" cy=\"400\"/></a:xfrm><a:prstGeom prst=\"ellipse\"><a:avLst/></a:prstGeom>", text: text)
        let group = "<xdr:grpSp><xdr:nvGrpSpPr><xdr:cNvPr id=\"8\" name=\"outer\"/></xdr:nvGrpSpPr><xdr:grpSpPr><a:xfrm flipV=\"true\"><a:off x=\"11\" y=\"13\"/><a:ext cx=\"1000\" cy=\"2000\"/><a:chOff x=\"7\" y=\"9\"/><a:chExt cx=\"100\" cy=\"200\"/></a:xfrm></xdr:grpSpPr><xdr:grpSp><xdr:grpSpPr/>" + child + "</xdr:grpSp>" + Self.shape() + "</xdr:grpSp>"
        let xml = Self.drawing(Self.oneCell(group))
        let wb = try Self.workbook(xml)
        let outer = try #require(wb.sheets[0].drawingInfo?.objects.first)
        #expect(outer.kind == .group && outer.children.map(\.kind) == [.group, .shape])
        #expect(outer.transform?.childOffset == .init(x: 7, y: 9) && outer.transform?.childExtent == .init(width: 100, height: 200))
        #expect(outer.transform?.isVerticallyFlipped == true)
        let inner = outer.children[0].children[0]
        #expect(inner.kind == .shape && inner.geometry == "ellipse" && inner.anchor == nil)
        #expect(inner.transform?.rotation == 30 && inner.transform?.isHorizontallyFlipped == true)
        let body = try #require(inner.textBody)
        #expect(body.attributes["lIns"] == "31750" && body.attributes["vert"] == "vert270" && body.paragraphs.count == 2)
        #expect(body.text == "日本語\nblue\nsecond" && body.paragraphs[0].runs.map(\.kind) == [.text, .lineBreak, .text])
        #expect(body.paragraphs[0].runs[0].font?.bold == true && body.paragraphs[0].runs[0].font?.color == Color(hex: "FF0000"))
        #expect(body.paragraphs[0].runs[0].latinTypeface == "+mn-lt" && body.paragraphs[0].runs[0].eastAsianTypeface == "游明朝")
        #expect(body.paragraphs[0].runs[2].font?.italic == true && body.paragraphs[0].runs[2].font?.color == .theme(4))
        #expect(wb.sheets[0].shapes.isEmpty, "source inspection does not claim group editing support")
        #expect(try Package.part("xl/drawings/drawing1.xml", of: wb.write(as: .xlsx).data) == xml)
        let back = try Workbook(data: wb.write(as: .xlsx).data)
        #expect(back.sheets[0].drawingInfo == wb.sheets[0].drawingInfo)
    }

    @Test func customGeometryEffectsAndColourTransformsAreInspectableAndLossesAreExplicit() throws {
        let geometry = "<a:custGeom><a:avLst><a:gd name=\"adj\" fmla=\"val 17\"/></a:avLst><a:pathLst><a:path w=\"100\" h=\"100\"><a:moveTo><a:pt x=\"0\" y=\"0\"/></a:moveTo><a:lnTo><a:pt x=\"100\" y=\"100\"/></a:lnTo></a:path></a:pathLst></a:custGeom><a:solidFill><a:srgbClr val=\"FF0000\"><a:alpha val=\"50000\"/></a:srgbClr></a:solidFill><a:effectLst><a:outerShdw blurRad=\"6350\" dist=\"31750\"><a:srgbClr val=\"000000\"/></a:outerShdw></a:effectLst>"
        let xml = Self.drawing(Self.oneCell(Self.shape(geometry)))
        var wb = try Self.workbook(xml)
        let object = try #require(wb.sheets[0].drawingInfo?.objects.first)
        #expect(object.geometry == "custom" && wb.sheets[0].shapes[0].geometry.rawValue == "custom" && !wb.sheets[0].shapes[0].geometry.isPreset)
        #expect(object.properties.map(\.name) == ["custGeom", "solidFill", "effectLst"])
        #expect(object.properties[0].xml.contains("fmla=\"val 17\"") && object.properties[0].namespaces["a"] == DrawingParts.nsDrawingMain)
        #expect(object.properties[1].xml.contains("alpha") && object.unmodelledProperties.contains("custom geometry"))
        #expect(try wb.write(as: .xlsx).warnings.isEmpty)
        #expect(try Package.part("xl/drawings/drawing1.xml", of: wb.write(as: .xlsx).data) == xml)
        wb.sheets[0].shapes[0].text = "edited"
        let rebuilt = try wb.write(as: .xlsx)
        #expect(rebuilt.warnings.contains { $0.context?.code == .drawingSimplified && $0.context?.preservation == .partial })
        #expect(rebuilt.warnings.contains { $0.kind == .degraded && $0.message.contains("written as a rectangle") })
        #expect(try !Package.part("xl/drawings/drawing1.xml", of: rebuilt.data).contains("custGeom"))
        for format in [SheetFormat.ods, .numbers] {
            #expect(try wb.write(as: format).warnings.contains { $0.context?.code == .drawingSimplified })
        }
    }

    @Test func excessiveGroupDepthLeavesTheOriginalDrawingPreservedWithADiagnostic() throws {
        let nested = String(repeating: "<xdr:grpSp><xdr:grpSpPr/>", count: 129) + Self.shape()
            + String(repeating: "</xdr:grpSp>", count: 129)
        let xml = Self.drawing(Self.oneCell(nested))
        let wb = try Self.workbook(xml)
        #expect(wb.sheets[0].drawingInfo == nil && wb.sheets[0].shapes.isEmpty)
        #expect(wb.readWarnings.contains { $0.context?.code == .drawingUnreadable && $0.context?.preservation == .preserved })
        #expect(try Package.part("xl/drawings/drawing1.xml", of: wb.write(as: .xlsx).data) == xml)
    }

    @Test func extensionMarkupCannotOverwriteKnownDrawingSemantics() throws {
        let text = "<xdr:txBody><a:bodyPr/><a:p><a:r><a:t>real</a:t></a:r></a:p></xdr:txBody>"
        let source = "<a:xfrm rot=\"1800000\"><a:off x=\"11\" y=\"13\"/><a:ext cx=\"100\" cy=\"200\"/></a:xfrm><a:prstGeom prst=\"ellipse\"><a:avLst/></a:prstGeom>"
            + "<a:extLst><a:ext uri=\"urn:test\"><v:spPr xmlns:v=\"urn:test\"><v:xfrm rot=\"900000\"/><v:prstGeom prst=\"triangle\"/><v:oneCellAnchor/><v:grpSp/><v:txBody><v:p><v:r><v:t>fake</v:t></v:r></v:p></v:txBody></v:spPr><a:xfrm rot=\"60000\"/><a:prstGeom prst=\"diamond\"/></a:ext></a:extLst>"
        let xml = Self.drawing(Self.oneCell(Self.shape(source, text: text)))
        let wb = try Self.workbook(xml)
        let object = try #require(wb.sheets[0].drawingInfo?.objects.first)
        #expect(wb.sheets[0].drawingInfo?.objects.count == 1 && object.children.isEmpty)
        #expect(object.transform?.rotation == 30 && object.geometry == "ellipse" && object.textBody?.text == "real")
        #expect(wb.sheets[0].shapes[0].geometry == .ellipse && wb.sheets[0].shapes[0].text == "real")
        #expect(object.properties.contains { $0.name == "extLst" && $0.xml.contains("900000") })
        #expect(try Package.part("xl/drawings/drawing1.xml", of: wb.write(as: .xlsx).data) == xml)
    }

    @Test func excessiveUnknownXMLDepthAlsoUsesThePreservationFallback() throws {
        let nested = String(repeating: "<v:w xmlns:v=\"urn:vendor\">", count: 257)
            + "<a:xfrm rot=\"1\"/>" + String(repeating: "</v:w>", count: 257)
        let xml = Self.drawing(Self.oneCell(Self.shape("<a:extLst><a:ext uri=\"urn:test\">" + nested + "</a:ext></a:extLst>")))
        let wb = try Self.workbook(xml)
        #expect(wb.sheets[0].drawingInfo == nil)
        #expect(wb.readWarnings.contains { $0.context?.code == .drawingUnreadable && $0.context?.preservation == .preserved })
        #expect(try Package.part("xl/drawings/drawing1.xml", of: wb.write(as: .xlsx).data) == xml)
    }

    @Test func sourcePictureAndChartPositionsAreUsedByReconstruction() throws {
        var wb = Workbook()
        wb.sheets[0].addImage(try SheetImage(data: DrawingReadTests.png()), at: "B3", sizing: .scaled(width: 20, height: 10))
        var chart = Chart(.column, title: "source")
        chart.addSeries(values: "A1:A2")
        wb.sheets[0].addChart(chart, over: "C4:D8")
        let original = try wb.write(as: .xlsx).data
        let xml = try Package.part("xl/drawings/drawing1.xml", of: original)
        let changedXML = xml.replacingOccurrences(of: "<xdr:colOff>0</xdr:colOff>", with: "<xdr:colOff>31750</xdr:colOff>")
            .replacingOccurrences(of: "<xdr:rowOff>0</xdr:rowOff>", with: "<xdr:rowOff>123</xdr:rowOff>")
        let zip = try ZipArchive(data: original), out = ZipWriter()
        for name in zip.names { out.add(name, name == "xl/drawings/drawing1.xml" ? Data(changedXML.utf8) : try zip.read(name)) }
        wb = try Workbook(data: out.finish())
        let imageAnchor = wb.sheets[0].images[0].drawingAnchor, chartAnchor = wb.sheets[0].charts[0].drawingAnchor
        wb.sheets[0].charts[0].title = "edited"
        let rebuilt = try Workbook(data: wb.write(as: .xlsx).data)
        #expect(rebuilt.sheets[0].images[0].drawingAnchor == imageAnchor)
        #expect(rebuilt.sheets[0].charts[0].drawingAnchor == chartAnchor)
        wb.sheets[0].images[0].anchor = .cell(CellRef("A1")!, sizing: .original)
        wb.sheets[0].charts[0].frame = CanvasRect(x: 0, y: 0, width: 100, height: 100)
        #expect(wb.sheets[0].images[0].drawingAnchor == nil && wb.sheets[0].charts[0].drawingAnchor == nil)
    }
}
