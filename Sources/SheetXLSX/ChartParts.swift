import Foundation
import SheetCore

/// The chart part (`c:chartSpace`) and its anchor on the drawing (spec Appendix B.34).
///
/// The element order follows the schema — CT_Chart (title, plotArea, legend, plotVisOnly), the chart-group
/// sequences (barDir → grouping → varyColors → ser → axId), CT_*Ser (idx, order, tx, cat, val) — which is what
/// Excel actually checks. The structure was learned from libxlsxwriter's chart.c (BSD-2, consulted as a
/// reference; no code copied — see NOTICE).
enum ChartParts {
    static let contentType = "application/vnd.openxmlformats-officedocument.drawingml.chart+xml"
    /// Relationship type suffix, against `XMLWriter.nsRel`.
    static let relationshipType = "/chart"
    static let nsChart = "http://schemas.openxmlformats.org/drawingml/2006/chart"

    /// A whole chart part. `sheetName` qualifies unqualified series ranges — chart references accept nothing
    /// but sheet-qualified absolute A1.
    static func chartXML(_ chart: Chart, sheetName: String) -> String {
        var x = XMLWriter.header
        x += "<c:chartSpace xmlns:c=\"\(nsChart)\" xmlns:a=\"\(DrawingParts.nsDrawingMain)\" xmlns:r=\"\(XMLWriter.nsRel)\">"
        x += "<c:chart>"
        if let title = chart.title {
            x += "<c:title><c:tx><c:rich><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(XML.esc(title))</a:t></a:r></a:p></c:rich></c:tx>"
                + "<c:overlay val=\"0\"/></c:title><c:autoTitleDeleted val=\"0\"/>"
        }
        x += "<c:plotArea><c:layout/>"
        x += groupXML(chart, sheetName: sheetName)
        if chart.kind != .pie {
            x += "<c:catAx><c:axId val=\"1\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling>"
                + "<c:delete val=\"0\"/><c:axPos val=\"\(chart.kind == .bar ? "l" : "b")\"/><c:crossAx val=\"2\"/></c:catAx>"
            x += "<c:valAx><c:axId val=\"2\"/><c:scaling><c:orientation val=\"minMax\"/></c:scaling>"
                + "<c:delete val=\"0\"/><c:axPos val=\"\(chart.kind == .bar ? "b" : "l")\"/><c:crossAx val=\"1\"/></c:valAx>"
        }
        x += "</c:plotArea>"
        if chart.legend { x += "<c:legend><c:legendPos val=\"r\"/><c:overlay val=\"0\"/></c:legend>" }
        x += "<c:plotVisOnly val=\"1\"/></c:chart></c:chartSpace>"
        return x
    }

    private static func groupXML(_ chart: Chart, sheetName: String) -> String {
        let sers = chart.series.enumerated().map { i, s in seriesXML(s, index: i, kind: chart.kind, sheetName: sheetName) }.joined()
        switch chart.kind {
        case .column, .bar:
            return "<c:barChart><c:barDir val=\"\(chart.kind == .bar ? "bar" : "col")\"/>"
                + "<c:grouping val=\"clustered\"/><c:varyColors val=\"0\"/>" + sers
                + "<c:axId val=\"1\"/><c:axId val=\"2\"/></c:barChart>"
        case .line:
            return "<c:lineChart><c:grouping val=\"standard\"/><c:varyColors val=\"0\"/>" + sers
                + "<c:marker val=\"1\"/><c:axId val=\"1\"/><c:axId val=\"2\"/></c:lineChart>"
        case .pie:
            return "<c:pieChart><c:varyColors val=\"1\"/>" + sers + "<c:firstSliceAng val=\"0\"/></c:pieChart>"
        }
    }

    private static func seriesXML(_ series: Chart.Series, index: Int, kind: Chart.Kind, sheetName: String) -> String {
        var x = "<c:ser><c:idx val=\"\(index)\"/><c:order val=\"\(index)\"/>"
        if let name = series.name { x += "<c:tx><c:v>\(XML.esc(name))</c:v></c:tx>" }
        if kind == .line { x += "<c:marker><c:symbol val=\"none\"/></c:marker>" }
        if let cats = series.categories {
            x += "<c:cat><c:strRef><c:f>\(XML.esc(qualify(cats, sheet: sheetName)))</c:f></c:strRef></c:cat>"
        }
        x += "<c:val><c:numRef><c:f>\(XML.esc(qualify(series.values, sheet: sheetName)))</c:f></c:numRef></c:val>"
        if kind == .line { x += "<c:smooth val=\"0\"/>" }
        x += "</c:ser>"
        return x
    }

    /// `B2:B13` → `'集計'!$B$2:$B$13`. A reference that already names a sheet passes through untouched.
    static func qualify(_ ref: String, sheet: String) -> String {
        if ref.contains("!") { return ref }
        let absolute = CellRange(ref).map { range in
            "$\(CellRef.columnName(range.minCol))$\(range.minRow + 1):$\(CellRef.columnName(range.maxCol))$\(range.maxRow + 1)"
        } ?? ref
        let needsQuotes = sheet.contains(where: { !$0.isLetter && !$0.isNumber && $0 != "_" })
        let name = needsQuotes ? "'\(sheet.replacingOccurrences(of: "'", with: "''"))'" : sheet
        return "\(name)!\(absolute)"
    }

    /// The chart's anchor on the drawing: a graphic frame over the range, both corners following their cells.
    static func anchorXML(over range: CellRange, shapeID: Int, relID: String) -> String {
        let ns = "xmlns:xdr=\"\(DrawingParts.nsSpreadsheetDrawing)\" xmlns:a=\"\(DrawingParts.nsDrawingMain)\""
        func at(col: Int, row: Int) -> String {
            "<xdr:col>\(col)</xdr:col><xdr:colOff>0</xdr:colOff><xdr:row>\(row)</xdr:row><xdr:rowOff>0</xdr:rowOff>"
        }
        return "<xdr:twoCellAnchor \(ns)><xdr:from>\(at(col: range.minCol, row: range.minRow))</xdr:from>"
            + "<xdr:to>\(at(col: range.maxCol + 1, row: range.maxRow + 1))</xdr:to>"
            + "<xdr:graphicFrame macro=\"\"><xdr:nvGraphicFramePr>"
            + "<xdr:cNvPr id=\"\(shapeID)\" name=\"Chart \(shapeID)\"/><xdr:cNvGraphicFramePr/></xdr:nvGraphicFramePr>"
            + "<xdr:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/></xdr:xfrm>"
            + "<a:graphic><a:graphicData uri=\"\(nsChart)\">"
            + "<c:chart xmlns:c=\"\(nsChart)\" xmlns:r=\"\(XMLWriter.nsRel)\" r:id=\"\(relID)\"/>"
            + "</a:graphicData></a:graphic></xdr:graphicFrame><xdr:clientData/></xdr:twoCellAnchor>"
    }
}
