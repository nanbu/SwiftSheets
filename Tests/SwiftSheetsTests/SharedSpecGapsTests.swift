import Foundation
import Testing
@testable import SheetCore
@testable import SheetODS
@testable import SheetXLSX
import SwiftSheets

/// Three things the public specifications share that one format's codec lacked (spec Appendix B.40.4): the ODF
/// structure lock, OOXML's iteration and full-precision settings, and the matrix row for ZIP64.
@Suite struct SharedSpecGapsTests {
    // MARK: - The ODF structure lock

    /// `office:spreadsheet table:structure-protected` is Excel's `lockStructure`: written, read back, and carried
    /// across formats in both directions.
    @Test func theStructureLockRoundTripsThroughODS() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        wb.protection.lockStructure = true
        let written = try wb.write(as: .ods)
        #expect(!written.warnings.contains { $0.message.contains("workbook protection") }, "the lock is written, not dropped: \(written.warnings.map(\.message))")
        let content = String(decoding: try ZipArchive(data: written.data).read("content.xml"), as: UTF8.self)
        #expect(content.contains("<office:spreadsheet table:structure-protected=\"true\">"))
        let back = try Workbook(data: written.data)
        #expect(back.protection.lockStructure)
        // and the way back to Excel keeps it
        let xlsx = try Workbook(data: try back.data(as: .xlsx))
        #expect(xlsx.protection.lockStructure)

        // an unlocked workbook writes no attribute, and reads back unlocked
        var plain = Workbook(); plain.sheets[0]["A1"] = "y"
        let plainContent = String(decoding: try ZipArchive(data: try plain.data(as: .ods)).read("content.xml"), as: UTF8.self)
        #expect(!plainContent.contains("structure-protected"))
        #expect(!(try Workbook(data: try plain.data(as: .ods))).protection.lockStructure)
    }

    /// What ODF cannot say about workbook protection is still said: the window lock, the revision lock and the
    /// passwords are reported, and the structure lock alone is not.
    @Test func whatODFCannotSayAboutProtectionIsReported() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "x"
        wb.protection.lockWindows = true
        wb.protection.setPassword("pw")
        let result = try wb.write(as: .ods)
        let about = result.warnings.filter { $0.message.contains("workbook protection") }
        #expect(about.count == 1 && about[0].message.contains("the window lock") && about[0].message.contains("the password"), "\(about)")
        #expect(!(try Workbook(data: result.data)).protection.lockStructure)
    }

    /// A file LibreOffice itself wrote with the structure protected reads as locked; and LibreOffice keeps the
    /// lock this library writes when it re-saves the file — the judge for the attribute's spelling.
    @Test(.enabled(if: ODSCodecTests.hasLibreOffice, "LibreOffice is not installed at \(ODSCodecTests.soffice)"))
    func libreOfficeKeepsTheStructureLock() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = "locked"
        wb.protection.lockStructure = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swiftsheets-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("locked.ods")
        try wb.write(to: file)
        // ODS → ODS through LibreOffice: a re-save by the reference implementation
        let outdir = dir.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outdir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ODSCodecTests.soffice)
        p.arguments = ["-env:UserInstallation=file://\(dir.appendingPathComponent("profile").path)", "--headless", "--convert-to", "ods", "--outdir", outdir.path, file.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let resaved = outdir.appendingPathComponent("locked.ods")
        try #require(FileManager.default.fileExists(atPath: resaved.path), Comment(rawValue: "LibreOffice did not produce the file: \(log)"))
        let content = String(decoding: try ZipArchive(data: try Data(contentsOf: resaved)).read("content.xml"), as: UTF8.self)
        #expect(content.contains("table:structure-protected=\"true\""), "LibreOffice kept the lock it read from this library's file")
        #expect(try Workbook(contentsOf: resaved).protection.lockStructure)
    }

    // MARK: - OOXML's calculation properties

    /// Iteration and full precision are `<calcPr>` attributes in OOXML: read into the model's calculation settings,
    /// written back, and carried between XLSX and ODS in both directions.
    @Test func iterationAndPrecisionRoundTripThroughXLSX() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.calculationSettings.iterationEnabled = true
        wb.calculationSettings.iterationSteps = 50
        wb.calculationSettings.iterationMaximumDifference = 0.01
        wb.calculationSettings.precisionAsShown = true
        let result = try wb.write(as: .xlsx)
        #expect(!result.warnings.contains { $0.message.contains("calculation setting") }, "OOXML has these settings; nothing to report: \(result.warnings.map(\.message))")
        let xml = String(decoding: try ZipArchive(data: result.data).read("xl/workbook.xml"), as: UTF8.self)
        #expect(xml.contains("iterate=\"1\"") && xml.contains("iterateCount=\"50\"") && xml.contains("iterateDelta=\"0.01\"") && xml.contains("fullPrecision=\"0\""), Comment(rawValue: xml))
        let back = try Workbook(data: result.data)
        #expect(back.calculationSettings.iterationEnabled && back.calculationSettings.iterationSteps == 50)
        #expect(back.calculationSettings.iterationMaximumDifference == 0.01 && back.calculationSettings.precisionAsShown)
        // XLSX → ODS → XLSX keeps them: the two spellings mean the same thing
        let ods = try Workbook(data: try back.data(as: .ods))
        #expect(ods.calculationSettings.iterationEnabled && ods.calculationSettings.iterationSteps == 50 && ods.calculationSettings.precisionAsShown)
        let again = try Workbook(data: try ods.data(as: .xlsx))
        #expect(again.calculationSettings.iterationEnabled && again.calculationSettings.precisionAsShown)
        // a setting only ODF has is still reported when writing XLSX
        var regex = Workbook(); regex.sheets[0]["A1"] = 1
        regex.calculationSettings.useRegularExpressions = true
        #expect(try regex.write(as: .xlsx).warnings.contains { $0.message.contains("regular expression") })
    }

    /// The other attributes of `<calcPr>` travel through a same-format save; a plain workbook still asks for a
    /// full recalculation, since this library computes nothing.
    @Test func theRestOfCalcPrIsCarried() throws {
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="S" sheetId="1" r:id="rId1"/></sheets><calcPr calcId="191029" calcMode="manual" refMode="R1C1" iterate="1" iterateCount="7"/></workbook>
        """
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        var package = try ZipArchive(data: try wb.data(as: .xlsx))
        var zip = ZipWriter()
        for name in package.names {
            zip.add(name, name == "xl/workbook.xml" ? Data(workbook.utf8) : try package.read(name))
        }
        let read = try Workbook(data: zip.finish())
        #expect(read.calculationSettings.iterationEnabled && read.calculationSettings.iterationSteps == 7)
        #expect(read.preserved.calcPrAttributes["calcMode"] == "manual")
        let saved = String(decoding: try ZipArchive(data: try read.data(as: .xlsx)).read("xl/workbook.xml"), as: UTF8.self)
        #expect(saved.contains("calcMode=\"manual\"") && saved.contains("refMode=\"R1C1\"") && saved.contains("calcId=\"191029\""), Comment(rawValue: saved))
        #expect(saved.contains("iterate=\"1\"") && saved.contains("iterateCount=\"7\"") && saved.contains("fullCalcOnLoad=\"1\""))
        _ = package
        package = try ZipArchive(data: try Workbook().data(as: .xlsx))
        let fresh = String(decoding: try package.read("xl/workbook.xml"), as: UTF8.self)
        #expect(fresh.contains("<calcPr calcId=\"124519\" fullCalcOnLoad=\"1\"/>"), Comment(rawValue: fresh))
    }

    /// The matrix says what the code does: ZIP64 is read and written (spec Appendix B.39.1), and every format has
    /// its row-by-row reader.
    @Test func theMatrixNamesTheSharedFeatures() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: root.appending(path: "scripts/spec-feature-matrix.json"))) as! [String: Any]
        var status: [String: (String, String)] = [:]
        for format in json["formats"] as! [[String: Any]] {
            for area in format["areas"] as! [[String: Any]] {
                for feature in area["features"] as! [[String: Any]] {
                    status[feature["id"] as! String] = (feature["read"] as! String, feature["write"] as! String)
                }
            }
        }
        #expect(status["xlsx.package.zip64"]! == ("full", "full"))
        #expect(status["ods.protect.workbook"]! == ("full", "full"))
        for id in ["xlsx.stream.read", "ods.stream.read", "num.stream.read"] { #expect(status[id]?.0 == "partial", Comment(rawValue: id)) }
    }
}
