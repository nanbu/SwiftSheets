import Foundation
import Testing
@testable import SheetNumbers
@testable import SheetCore
import SwiftSheets

/// Pictures, shapes and text boxes on a Numbers sheet's canvas (spec Appendix B.83). `canvas-15.numbers` was made
/// by Numbers 15.3.1 itself over AppleScript — one picture (a 40×30 red PNG), one text item, one shape — so what
/// the reader finds in it is what Numbers writes, and what the writer produces is compared with the same archives.
@Suite struct NumbersCanvasTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/numbers")
    static let images = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/images")
    static let parity = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "NumbersParity")
    static let stage = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: ".build/numbers-judge/canvas")

    static func png() throws -> SheetImage { try SheetImage(data: try Data(contentsOf: images.appendingPathComponent("tiny.png"))) }
    static func gif() throws -> SheetImage { try SheetImage(data: try Data(contentsOf: images.appendingPathComponent("tiny.gif"))) }

    /// Runs `numbers_app.py` from the parity suite; nil when Python or the script cannot run at all.
    /// One document at a time: Numbers answers about its front document, so two judges at once confuse it.
    static let judgeLock = NSLock()

    static func numbersApp(_ arguments: [String]) -> (status: Int32, output: String)? {
        judgeLock.lock(); defer { judgeLock.unlock() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [parity.appending(path: "numbers_app.py").path] + arguments
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, out)
    }

    /// Whether Numbers itself can judge here: Apple's Numbers, an unlocked screen, Automation allowed — the
    /// driver's own `available()`, so a locked screen skips the judged tests with that reason instead of failing them.
    static let numbersCanJudge: Bool = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", "import sys; sys.path.insert(0, sys.argv[1]); import numbers_app; ok, why = numbers_app.available(); print(why); sys.exit(0 if ok else 3)", parity.path]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }()

    /// An anchor's frame rounded to whole points: the template's default row is 19.93 pt, not 20.
    static func points(_ anchor: SheetImage.Anchor) -> [Int] {
        guard case .absolute(let f) = anchor else { return [] }
        return [f.origin.x, f.origin.y, f.width, f.height].map { Int($0.rounded()) }
    }

    // MARK: - Reading what Numbers wrote

    @Test func readsThePictureAndTheShapesNumbersMade() throws {
        let wb = try Workbook(data: try Data(contentsOf: Self.fixtures.appendingPathComponent("canvas-15.numbers")))
        let sheet = wb.sheets[0]
        try #require(sheet.images.count == 1)
        let image = sheet.images[0]
        #expect(image.format == .png)
        #expect(image.pixelWidth == 40 && image.pixelHeight == 30)
        #expect(image.anchor == .absolute(CanvasRect(x: 200, y: 300, width: 40, height: 30)))
        // the bytes are the ones under Data/, digest and all
        #expect(SHA1.hash(image.data).base64EncodedString() == "QegeKP5ZdX7ehfJLnpBV5A/9Fng=")

        try #require(sheet.shapes.count == 2)
        let box = sheet.shapes[0], shape = sheet.shapes[1]
        #expect(box.geometry == .textBox)
        #expect(box.text == "Boxed text")
        #expect(box.fill == nil, "a text box has no fill")
        #expect(shape.geometry == .rectangle)
        #expect(shape.text == "Shape text")
        #expect(shape.fill == Color(hex: "FF000000"), "the shape style's fill is black")
        #expect(shape.anchor == .absolute(CanvasRect(x: 400, y: 500, width: 100, height: 100)))
        // nothing on the canvas is left to report: the image and both shapes came into the model
        #expect(!wb.readWarnings.contains { $0.message.contains("an image") || $0.message.contains("a shape") },
                "\(wb.readWarnings.map(\.message))")
    }

    // MARK: - Writing, read back by our own reader

    @Test func writesPicturesAndReadsThemBack() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        wb.sheets[0].addImage(try Self.png(), at: "B2")
        wb.sheets[0].addImage(try Self.gif(), over: "C3:D4")
        let result = try wb.write(as: .numbers)
        #expect(!result.warnings.contains { $0.message.contains("image") }, "\(result.warnings.map(\.message))")
        let back = try Workbook(data: result.data)
        try #require(back.sheets[0].images.count == 2)
        #expect(back.sheets[0].images[0].data == (try Self.png()).data)
        #expect(back.sheets[0].images[1].data == (try Self.gif()).data)
        // B2 against the first table at the origin: one default column (98 pt) across, one default row (20 pt) down,
        // the picture at its own pixel size
        #expect(Self.points(back.sheets[0].images[0].anchor) == [98, 20, 6, 4])
        // C3:D4: two columns and two rows in, two of each across
        #expect(Self.points(back.sheets[0].images[1].anchor) == [196, 40, 196, 40])
        // the package carries the bytes and their record
        let doc = try NumbersDocument(data: result.data)
        let records = doc.object(NumbersDocument.packageID)?.messages("datas") ?? []
        #expect(records.contains { $0.string("file_name") == "image1-16.png" }, "\(records.compactMap { $0.string("file_name") })")
        #expect(doc.blob("Data/image1-16.png") == (try Self.png()).data)
    }

    @Test func cellAnchorsFollowTheTablesOwnSizes() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        wb.sheets[0].setWidth(20, ofColumn: "A")     // 20 characters × 5.7 pt
        wb.sheets[0].setHeight(50, ofRow: 1)
        wb.sheets[0].addImage(try Self.png(), at: "B2", sizing: .fitCell)
        wb.sheets[0].addImage(try Self.png(), at: "A1", sizing: .scaled(width: 30, height: 12))
        let back = try Workbook(data: try wb.write(as: .numbers).data)
        try #require(back.sheets[0].images.count == 2)
        #expect(Self.points(back.sheets[0].images[0].anchor) == [114, 50, 98, 20])
        #expect(back.sheets[0].images[1].anchor == .absolute(CanvasRect(x: 0, y: 0, width: 30, height: 12)))
    }

    @Test func writesShapesAndTextBoxesAndReadsThemBack() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        wb.sheets[0].addTextBox("A note\non two lines", over: "B2:D3", font: Font(bold: true))
        var box = Shape(.rectangle, text: "Filled")
        box.fill = .rgb("FF3366")
        box.outline = Shape.Outline(color: .rgb("0000FF"), width: 2)
        wb.sheets[0].addShape(box, over: "F2:G4")
        wb.sheets[0].addShape(Shape(.rectangle), over: "A6:B7")
        let result = try wb.write(as: .numbers)
        #expect(!result.warnings.contains { $0.message.contains("shape") }, "\(result.warnings.map(\.message))")
        let back = try Workbook(data: result.data)
        try #require(back.sheets[0].shapes.count == 3)
        let note = back.sheets[0].shapes[0]
        #expect(note.geometry == .textBox)
        #expect(note.text == "A note\non two lines")
        #expect(Self.points(note.anchor) == [98, 20, 294, 40])
        let filled = back.sheets[0].shapes[1]
        #expect(filled.geometry == .rectangle)
        #expect(filled.text == "Filled")
        #expect(filled.fill == Color(hex: "FFFF3366"))
        #expect(filled.outline == Shape.Outline(color: Color(hex: "FF0000FF"), width: 2))
        let plain = back.sheets[0].shapes[2]
        #expect(plain.text == nil)
        #expect(plain.fill == Color(hex: "FF000000"), "the template shape style fills black")
    }

    /// Every geometry the writer draws comes back as itself (B.87): its unit path is recognised on the way in.
    @Test func drawnGeometriesRoundTrip() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        for (i, g) in NumbersCanvas.drawnGeometries.enumerated() {
            wb.sheets[0].addShape(Shape(g, text: g == .line ? nil : g.rawValue), over: CellRange(minRow: 2 + 3 * i, minColumn: 2, maxRow: 3 + 3 * i, maxColumn: 4))
        }
        let result = try wb.write(as: .numbers)
        #expect(!result.warnings.contains { $0.message.contains("written as a rectangle") }, "\(result.warnings.map(\.message))")
        let back = try Workbook(data: result.data).sheets[0].shapes
        #expect(back.map(\.geometry) == NumbersCanvas.drawnGeometries)
        #expect(NumbersCanvas.unitPath(.ellipse)?.filter { $0.kind == "curveTo" }.count == 4)
    }

    @Test func otherGeometriesAreWrittenAsRectanglesAndSaid() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        wb.sheets[0].addShape(Shape(.rightArrow, text: "go"), over: "B2:C3")
        var aligned = Shape(.textBox, text: "centred")
        aligned.textAlignment = .center
        wb.sheets[0].addShape(aligned, over: "B5:C6")
        let result = try wb.write(as: .numbers)
        wb.sheets[0].addShape(Shape(Shape.Geometry(rawValue: "hexagon"), text: "six"), over: "E2:F3")
        #expect(result.warnings.contains { $0.kind == .degraded && $0.message.contains("text alignment of a shape is not written") })
        let again = try wb.write(as: .numbers)
        #expect(again.warnings.contains { $0.kind == .degraded && $0.message.contains("geometry hexagon was written as a rectangle") }, "\(again.warnings.map(\.message))")
        let back = try Workbook(data: again.data)
        try #require(back.sheets[0].shapes.count == 3)
        #expect(back.sheets[0].shapes[0].geometry == .rightArrow)
        #expect(back.sheets[0].shapes[2].geometry == .rectangle && back.sheets[0].shapes[2].text == "six")
    }

    /// What Numbers wrote comes back out as new objects: the picture and the shapes of the fixture survive a pass
    /// through our writer (no snapshot is kept — the ODS rule, spec Appendix B.73).
    @Test func whatNumbersMadeSurvivesOurWriter() throws {
        let wb = try Workbook(data: try Data(contentsOf: Self.fixtures.appendingPathComponent("canvas-15.numbers")))
        let back = try Workbook(data: try wb.write(as: .numbers).data)
        try #require(back.sheets[0].images.count == 1)
        #expect(back.sheets[0].images[0].data == wb.sheets[0].images[0].data)
        #expect(back.sheets[0].images[0].anchor == wb.sheets[0].images[0].anchor)
        #expect(back.sheets[0].shapes.map(\.text) == ["Boxed text", "Shape text"])
        #expect(back.sheets[0].shapes.map(\.geometry) == [.textBox, .rectangle])
    }

    // MARK: - Judged by Numbers itself

    /// Numbers keeps every drawn geometry's path as given (B.87): curves and all come back after it saves.
    @Test(.enabled(if: NumbersCanvasTests.numbersCanJudge, "Numbers.app is not here, or this terminal may not drive it"))
    func numbersItselfKeepsTheDrawnGeometries() throws {
        try FileManager.default.createDirectory(at: Self.stage, withIntermediateDirectories: true)
        var wb = Workbook()
        wb.sheets[0]["A1"] = "shapes"
        for (i, g) in NumbersCanvas.drawnGeometries.enumerated() {
            wb.sheets[0].addShape(Shape(g), over: CellRange(minRow: 2 + 3 * i, minColumn: 2, maxRow: 3 + 3 * i, maxColumn: 4))
        }
        let written = Self.stage.appending(path: "geometries.numbers")
        try wb.write(as: .numbers).data.write(to: written)
        let resaved = Self.stage.appending(path: "geometries-resaved.numbers")
        let run = try #require(Self.numbersApp(["resave", written.path, resaved.path]))
        try #require(run.status == 0, Comment(rawValue: "Numbers did not save the document again: \(run.output)"))
        let back = try Workbook(data: try Data(contentsOf: resaved)).sheets[0].shapes
        #expect(back.map(\.geometry) == NumbersCanvas.drawnGeometries)
    }

    /// Numbers opens what we wrote, saves it again, and the picture's bytes and the text box's text are in what
    /// it saved. Skipped, with the reason, where Numbers cannot judge.
    @Test(.enabled(if: NumbersCanvasTests.numbersCanJudge, "Numbers.app is not here, or this terminal may not drive it"))
    func numbersItselfKeepsThePictureAndTheTextBox() throws {
        // the stage is shared with the other judged tests, which may be writing into it: never remove it
        try FileManager.default.createDirectory(at: Self.stage, withIntermediateDirectories: true)
        var wb = Workbook()
        wb.sheets[0]["A1"] = "canvas"
        wb.sheets[0].addImage(try Self.png(), at: "B2")
        wb.sheets[0].addTextBox("Boxed by SwiftSheets", over: "B4:D5")
        var shape = Shape(.rectangle, text: "Shape")
        shape.fill = .rgb("FF3366")
        wb.sheets[0].addShape(shape, over: "F2:G4")
        let written = Self.stage.appending(path: "canvas.numbers")
        try wb.write(as: .numbers).data.write(to: written)
        let resaved = Self.stage.appending(path: "canvas-resaved.numbers")
        let run = try #require(Self.numbersApp(["resave", written.path, resaved.path]))
        try #require(run.status == 0, Comment(rawValue: "Numbers did not save the document again: \(run.output)"))
        let back = try Workbook(data: try Data(contentsOf: resaved))
        try #require(back.sheets[0].images.count == 1, Comment(rawValue: "Numbers kept \(back.sheets[0].images.count) picture(s)"))
        #expect(back.sheets[0].images[0].data == (try Self.png()).data, "the bytes Numbers kept are ours")
        #expect(back.sheets[0].shapes.map(\.text) == ["Boxed by SwiftSheets", "Shape"])
        #expect(back.sheets[0]["A1"] == "canvas")
    }
}

