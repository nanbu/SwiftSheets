import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
@testable import SheetODS
import SwiftSheets

/// Shapes and text boxes (spec Appendix B.75): read from an XLSX drawing and an ODS table, written by both,
/// and — in XLSX — carried byte for byte until one of them is changed. SmartArt and groups of shapes stay bytes
/// and are named when a rebuild drops them. LibreOffice, where installed, judges what it can read back.
@Suite(.serialized) struct ShapeTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/drawings")
    static let xlsx = fixtures.appendingPathComponent("libreoffice-shapes.xlsx")
    static let ods = fixtures.appendingPathComponent("libreoffice-shapes.ods")
    static let smartArt = fixtures.appendingPathComponent("smartart-and-group.xlsx")
    static let tmp: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftSheetsShapes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// One of everything the model holds, over ranges, at a cell and at a fixed position.
    static func workbook() -> Workbook {
        var wb = Workbook()
        wb.sheets[0].name = "Draw"
        wb.sheets[0]["A1"] = 1
        var rect = Shape(.rectangle, text: "Hello\nWorld")
        rect.fill = Color(hex: "FF0000")
        rect.outline = Shape.Outline(color: Color(hex: "0000FF"), width: 2)
        rect.font = Font(name: "Arial", size: 14, bold: true, color: Color(hex: "00FF00"))
        rect.textAlignment = .center
        wb.sheets[0].addShape(rect, over: "B2:D5")
        var arrow = Shape(.rightArrow)
        arrow.fill = .theme(4)
        arrow.anchor = .cell(CellRef("F2")!, sizing: .scaled(width: 96, height: 48))
        wb.sheets[0].shapes.append(arrow)
        wb.sheets[0].addTextBox("A note\non two lines", over: "B8:E10", font: Font(size: 12, italic: true))
        var line = Shape(.line)
        line.outline = Shape.Outline(color: .black, width: 1.5)
        wb.sheets[0].addShape(line, over: "G8:J12")
        var ellipse = Shape(.ellipse, text: "free")
        ellipse.fill = Color(hex: "FFFF00")
        ellipse.anchor = .absolute(x: 300, y: 20, width: 120, height: 60)
        wb.sheets[0].shapes.append(ellipse)
        return wb
    }

    /// ODS keeps the sheet's own shapes (`table:shapes`) before the cells', so the order is the file's, not the
    /// model's: each shape is found by its geometry, which is distinct here.
    static func check(_ read: [Shape], _ label: String) {
        #expect(read.count == 5, "\(label): \(read.map(\.geometry))")
        let order: [Shape.Geometry] = [.rectangle, .rightArrow, .textBox, .line, .ellipse]
        let shapes = order.compactMap { g in read.first { $0.geometry == g } }
        guard shapes.count == 5 else { Issue.record("\(label): \(read.map(\.geometry))"); return }
        let rect = shapes[0]
        #expect(rect.geometry == .rectangle && rect.text == "Hello\nWorld", Comment(rawValue: label))
        #expect(rect.fill == .rgb("FFFF0000") && rect.outline?.color == .rgb("FF0000FF"), Comment(rawValue: label))
        #expect(abs((rect.outline?.width ?? 0) - 2) < 0.05, "\(label): \(String(describing: rect.outline))")
        #expect(rect.font?.bold == true && rect.font?.size == 14 && rect.font?.color == .rgb("FF00FF00") && rect.font?.name == "Arial", "\(label): \(String(describing: rect.font))")
        #expect(rect.textAlignment == .center, Comment(rawValue: label))
        #expect(rect.anchor == .span(CellRange("B2:D5")!), "\(label): \(rect.anchor)")
        #expect(shapes[1].geometry == .rightArrow && shapes[1].fill == .rgb("FF4472C4"), "\(label): the theme colour is written resolved")
        if case .cell(let ref, .scaled(let w, let h)) = shapes[1].anchor { #expect(ref == CellRef("F2") && w == 96 && h == 48, Comment(rawValue: label)) } else { Issue.record("\(label): \(shapes[1].anchor)") }
        #expect(shapes[2].geometry == .textBox && shapes[2].text == "A note\non two lines" && shapes[2].fill == nil && shapes[2].outline == nil, Comment(rawValue: label))
        #expect(shapes[2].font?.italic == true && shapes[2].font?.size == 12, "\(label): \(String(describing: shapes[2].font))")
        #expect(shapes[3].geometry == .line && shapes[3].anchor == .span(CellRange("G8:J12")!), Comment(rawValue: label))
        #expect(shapes[4].geometry == .ellipse && shapes[4].text == "free", Comment(rawValue: label))
        if case .absolute(let x, let y, let w, let h) = shapes[4].anchor {
            #expect(abs(x - 300) < 0.5 && abs(y - 20) < 0.5 && abs(w - 120) < 0.5 && abs(h - 60) < 0.5, "\(label): \(shapes[4].anchor)")
        } else { Issue.record("\(label): \(shapes[4].anchor)") }
    }

    // MARK: - reading what LibreOffice wrote

    @Test func readsLibreOfficesShapesFromXLSX() throws {
        let sheet = try Workbook(contentsOf: Self.xlsx).sheets[0]
        #expect(sheet.shapes.map(\.geometry) == [.rectangle, .rightArrow, .ellipse, .roundedRectangle, .textBox, .line, .diamond])
        let rect = sheet.shapes[0]
        #expect(rect.text == "Hello" && rect.fill == .rgb("FFFF0000") && rect.outline?.color == .rgb("FF0000FF"))
        #expect(abs((rect.outline?.width ?? 0) - 25200.0 / 12700) < 0.01)
        #expect(rect.font?.size == 14 && rect.font?.bold == true && rect.font?.color == .rgb("FF00FF00") && rect.font?.name == "游明朝体")
        #expect(rect.textAlignment == .center)
        let box = sheet.shapes[4]
        #expect(box.text == "Text box\nline 2" && box.fill == nil && box.outline == nil, "a text box: no fill, a line of width 0 with no fill")
        #expect(sheet.shapes[1].text == nil && sheet.shapes[1].fill == .rgb("FFFF0000"))
        #expect(sheet.shapes[6].text == "in cell")
        #expect(sheet.preserved.drawingUnmodelled.isEmpty, "\(sheet.preserved.drawingUnmodelled)")
        #expect(sheet.preserved.shapes == sheet.shapes)
    }

    @Test func readsLibreOfficesShapesFromODS() throws {
        let sheet = try Workbook(contentsOf: Self.ods).sheets[0]
        #expect(sheet.shapes.map(\.geometry) == [.rectangle, .rightArrow, .ellipse, .roundedRectangle, .textBox, .line, .diamond], "\(sheet.shapes.map(\.geometry))")
        let rect = sheet.shapes[0]
        #expect(rect.text == "Hello" && rect.fill == .rgb("FFFF0000") && rect.outline?.color == .rgb("FF0000FF"))
        #expect(abs((rect.outline?.width ?? 0) - 0.07 / 2.54 * 72) < 0.05, "\(String(describing: rect.outline))")
        #expect(rect.font?.size == 14 && rect.font?.bold == true && rect.font?.color == .rgb("FF00FF00"), "\(String(describing: rect.font))")
        #expect(rect.textAlignment == .center)
        if case .absolute = rect.anchor {} else { Issue.record("a shape among table:shapes is at a fixed position: \(rect.anchor)") }
        let box = sheet.shapes[4]
        #expect(box.text == "Text box\nline 2" && box.fill == nil && box.outline == nil)
        #expect(sheet.shapes[6].text == "in cell" && sheet.shapes[6].anchor == .span(CellRange("A2:B3")!), "\(sheet.shapes[6].anchor)")
        if case .absolute(let x, let y, let w, let h) = sheet.shapes[5].anchor {
            #expect(abs(x - 1 / 2.54 * 72) < 0.1 && abs(y - 7 / 2.54 * 72) < 0.1 && abs(w - 4 / 2.54 * 72) < 0.1 && abs(h - 1 / 2.54 * 72) < 0.1, "a line's box is its two ends: \(sheet.shapes[5].anchor)")
        } else { Issue.record("\(sheet.shapes[5].anchor)") }
    }

    // MARK: - the as-read snapshot (XLSX)

    @Test func untouchedShapesAreWrittenBackByteForByte() throws {
        let source = try Data(contentsOf: Self.xlsx)
        let wb = try Workbook(contentsOf: Self.xlsx)
        let result = try wb.write(as: .xlsx)
        #expect(try Package.part("xl/drawings/drawing1.xml", of: result.data) == Package.part("xl/drawings/drawing1.xml", of: source))
        #expect(result.warnings.isEmpty, "\(result.warnings.map(\.message))")
        #expect(try Workbook.read(result.data, format: .xlsx).workbook.sheets[0].shapes == wb.sheets[0].shapes)
    }

    @Test func anAddedShapeIsSplicedIntoTheSourceDrawing() throws {
        let source = try Package.part("xl/drawings/drawing1.xml", of: Data(contentsOf: Self.xlsx))
        var wb = try Workbook(contentsOf: Self.xlsx)
        wb.sheets[0].addTextBox("added here", over: "H20:J22")
        let result = try wb.write(as: .xlsx)
        let drawing = try Package.part("xl/drawings/drawing1.xml", of: result.data)
        #expect(drawing.hasPrefix(String(source.dropLast("</xdr:wsDr>".count))), "the source's anchors are the prefix")
        #expect(drawing.contains("txBox=\"1\"") && drawing.contains("<a:t>added here</a:t>"))
        let back = try Workbook.read(result.data, format: .xlsx).workbook.sheets[0]
        #expect(back.shapes.count == 8 && back.shapes[7].geometry == .textBox && back.shapes[7].text == "added here")
        #expect(back.shapes[7].anchor == .span(CellRange("H20:J22")!))
    }

    @Test func aChangedShapeRebuildsTheDrawing() throws {
        var wb = try Workbook(contentsOf: Self.xlsx)
        wb.sheets[0].shapes[0].text = "Changed"
        wb.sheets[0].shapes.remove(at: 3)
        let result = try wb.write(as: .xlsx)
        let drawing = try Package.part("xl/drawings/drawing1.xml", of: result.data)
        #expect(drawing.contains("<a:t>Changed</a:t>") && !drawing.contains("<a:t>Hello</a:t>"))
        #expect(result.warnings.isEmpty, "nothing in this drawing lay outside the model: \(result.warnings.map(\.message))")
        let back = try Workbook.read(result.data, format: .xlsx).workbook.sheets[0]
        #expect(back.shapes.count == 6 && back.shapes[0].text == "Changed" && back.shapes.map(\.geometry) == [.rectangle, .rightArrow, .ellipse, .textBox, .line, .diamond])
        #expect(back.shapes[0].fill == wb.sheets[0].shapes[0].fill && back.shapes[0].font == wb.sheets[0].shapes[0].font)
    }

    @Test func smartArtAndGroupsAreNamedAndKeptUntilARebuild() throws {
        let source = try Data(contentsOf: Self.smartArt)
        var wb = try Workbook(contentsOf: Self.smartArt)
        let sheet = wb.sheets[0]
        #expect(sheet.shapes.count == 1 && sheet.shapes[0].text == "Excel default")
        #expect(sheet.shapes[0].fill == .theme(4) && sheet.shapes[0].outline?.color == .theme(4, tint: -0.5), "a fresh Excel shape is coloured by its style references: \(String(describing: sheet.shapes[0].fill)) \(String(describing: sheet.shapes[0].outline))")
        #expect(sheet.preserved.drawingUnmodelled == ["a group of shapes", "SmartArt"], "\(sheet.preserved.drawingUnmodelled)")
        // untouched: bytes; added: spliced, and the SmartArt parts stay
        let same = try wb.write(as: .xlsx)
        #expect(try Package.part("xl/drawings/drawing1.xml", of: same.data) == Package.part("xl/drawings/drawing1.xml", of: source))
        #expect(same.warnings.isEmpty, "\(same.warnings.map(\.message))")
        wb.sheets[0].addShape(Shape(.ellipse), over: "A12:B14")
        let added = try wb.write(as: .xlsx)
        #expect(added.warnings.isEmpty, "\(added.warnings.map(\.message))")
        #expect(try ZipInspection(data: added.data).entryNames.contains("xl/diagrams/data1.xml"))
        #expect(try Package.part("xl/drawings/drawing1.xml", of: added.data).contains("diagram"))
        // changed: rebuilt, and what the model could not hold is named
        wb.sheets[0].shapes[0].text = "Changed"
        let rebuilt = try wb.write(as: .xlsx)
        #expect(rebuilt.warnings.contains { $0.kind == .dropped && $0.message.contains("a group of shapes, SmartArt") }, "\(rebuilt.warnings.map(\.message))")
        #expect(try !Package.part("xl/drawings/drawing1.xml", of: rebuilt.data).contains("diagram"))
        #expect(try Workbook.read(rebuilt.data, format: .xlsx).workbook.sheets[0].shapes.map(\.text) == ["Changed", nil])
    }

    // MARK: - writing

    @Test func shapesRoundTripThroughXLSX() throws {
        let result = try Self.workbook().write(as: .xlsx)
        #expect(result.warnings.isEmpty, "\(result.warnings.map(\.message))")
        let drawing = try Package.part("xl/drawings/drawing1.xml", of: result.data)
        #expect(drawing.contains("prst=\"rightArrow\"") && drawing.contains("txBox=\"1\"") && drawing.contains("<xdr:absoluteAnchor"))
        Self.check(try Workbook.read(result.data, format: .xlsx).workbook.sheets[0].shapes, "xlsx")
    }

    @Test func shapesRoundTripThroughODS() throws {
        let result = try Self.workbook().write(as: .ods)
        #expect(result.warnings.isEmpty, "\(result.warnings.map(\.message))")
        let content = try Package.part("content.xml", of: result.data)
        #expect(content.contains("draw:type=\"ooxml-rightArrow\"") || content.contains("draw:type=\"right-arrow\""))
        #expect(content.contains("<draw:text-box>") && content.contains("<draw:line ") && content.contains("<table:shapes>"))
        #expect(content.contains("draw:fill-color=\"#4472c4\""), "the theme colour is resolved before it is written")
        Self.check(try Workbook.read(result.data, format: .ods).workbook.sheets[0].shapes, "ods")
    }

    @Test func anUnknownGeometryIsARectangleInXLSXAndSaysSo() throws {
        var wb = Workbook()
        wb.sheets[0].addShape(Shape(Shape.Geometry(rawValue: "smiley-from-somewhere")), over: "A1:B2")
        let result = try wb.write(as: .xlsx)
        #expect(result.warnings.contains { $0.kind == .degraded && $0.message.contains("smiley-from-somewhere") && $0.message.contains("rectangle") }, "\(result.warnings.map(\.message))")
        #expect(try Package.part("xl/drawings/drawing1.xml", of: result.data).contains("prst=\"rect\""))
        #expect(!Shape.Geometry(rawValue: "smiley-from-somewhere").isPreset && Shape.Geometry.rightArrow.isPreset && Shape.Geometry.textBox.isPreset)
    }

    @Test func numbersSaysShapesAreDropped() throws {
        let result = try Self.workbook().write(as: .numbers)
        #expect(result.warnings.contains { $0.kind == .dropped && $0.message.contains("5 shape(s) / text box(es) dropped") }, "\(result.warnings.map(\.message))")
    }

    @Test func shapesAreCarriedBetweenTheFormats() throws {
        let fromXLSX = try Workbook(contentsOf: Self.xlsx)
        let ods = try fromXLSX.write(as: .ods)
        #expect(!ods.warnings.contains { $0.message.contains("shape") }, "\(ods.warnings.map(\.message))")
        let back = try Workbook.read(ods.data, format: .ods).workbook.sheets[0]
        // the diamond, anchored in a cell, is written in its cell and so read after the sheet's own shapes
        #expect(back.shapes.map(\.geometry) == [.diamond, .rectangle, .rightArrow, .ellipse, .roundedRectangle, .textBox, .line], "\(back.shapes.map(\.geometry))")
        #expect(Set(back.shapes.map { $0.text ?? "" }) == Set(fromXLSX.sheets[0].shapes.map { $0.text ?? "" }))
        let fromODS = try Workbook(contentsOf: Self.ods)
        let xlsx = try fromODS.write(as: .xlsx)
        #expect(!xlsx.warnings.contains { $0.message.contains("shape") }, "\(xlsx.warnings.map(\.message))")
        let back2 = try Workbook.read(xlsx.data, format: .xlsx).workbook.sheets[0]
        #expect(back2.shapes.map(\.geometry) == fromODS.sheets[0].shapes.map(\.geometry))
    }

    // MARK: - LibreOffice as the judge

    @Test(.enabled(if: ODSCodecTests.hasLibreOffice, "LibreOffice is not installed at \(ODSCodecTests.soffice)"))
    func libreOfficeReadsWhatTheXLSXWriterDrew() throws {
        let file = Self.tmp.appendingPathComponent("shapes-out.xlsx")
        try Self.workbook().write(to: file, as: .xlsx)
        let ods = try ODSImageTests.convert(file, to: "ods")
        let sheet = try Workbook(contentsOf: ods).sheets[0]
        #expect(sheet.shapes.count == 5, "\(sheet.shapes.map(\.geometry))")
        #expect(sheet.shapes.map(\.geometry).contains(.rightArrow) && sheet.shapes.map(\.geometry).contains(.ellipse))
        #expect(sheet.shapes.contains { $0.text == "Hello\nWorld" && $0.fill == .rgb("FFFF0000") })
        #expect(sheet.shapes.contains { $0.text == "A note\non two lines" })
    }

    @Test(.enabled(if: ODSCodecTests.hasLibreOffice, "LibreOffice is not installed at \(ODSCodecTests.soffice)"))
    func libreOfficeReadsWhatTheODSWriterDrew() throws {
        let file = Self.tmp.appendingPathComponent("shapes-out.ods")
        try Self.workbook().write(to: file, as: .ods)
        let xlsx = try ODSImageTests.convert(file, to: "xlsx")
        let drawing = try Package.part("xl/drawings/drawing1.xml", of: Data(contentsOf: xlsx))
        #expect(drawing.contains("prst=\"rightArrow\"") && drawing.contains("prst=\"ellipse\"") && drawing.contains("txBox=\"1\""), "LibreOffice named the presets: \(drawing.prefix(300))")
        let sheet = try Workbook(contentsOf: xlsx).sheets[0]
        #expect(sheet.shapes.count == 5, "\(sheet.shapes.map(\.geometry))")
        #expect(sheet.shapes.contains { $0.text == "Hello\nWorld" && $0.fill == .rgb("FFFF0000") && $0.font?.bold == true })
    }
}
