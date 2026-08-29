import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

/// Sheet and workbook protection, editable windows inside a protected sheet, and "what if" scenarios.
@Suite struct ProtectionTests {

    /// openpyxl's own hashes, digit for digit — the same file must lock and unlock in both libraries.
    // openpyxl: utils/tests/test_protection.py::test_password
    @Test(arguments: [("secret", "DAA7"), ("", "CE4B"), ("日本語", "CDC8"), ("a", "CE88"),
                      ("abcdefghijklmnop", "C643"), ("A1!", "CF06")])
    func theLegacyHashMatchesTheReference(_ password: String, _ expected: String) {
        #expect(LegacyPasswordHash.hash(password) == expected)
    }

    /// Protection on, a password set, and the permissions written the way the file spells them — inverted.
    // openpyxl: worksheet/tests/test_protection.py::TestSheetProtection::test_ctor
    // openpyxl: worksheet/tests/test_protection.py::TestSheetProtection::test_bool
    // openpyxl: worksheet/tests/test_protection.py::test_ctor_with_password
    // openpyxl: worksheet/tests/test_protection.py::test_explicit_password
    @Test func sheetProtectionRoundTrips() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws["A1"] = 1
        ws["B1"] = 2; ws.style("B1") { $0.protection = Protection(locked: false) }   // the one editable cell
        var p = SheetProtection.on
        p.setPassword("secret")
        p.allowsSorting = true
        p.allowsFiltering = true
        p.allowsSelectingLockedCells = false
        p.allowsEditingObjects = false
        wb.sheets[0].protection = p
        wb.sheets[0] = { var s = ws; s.protection = p; return s }()

        let data = try wb.data(as: .xlsx)
        let xml = try Package.part("xl/worksheets/sheet1.xml", of: data)
        #expect(xml.contains("password=\"DAA7\"") && xml.contains("sheet=\"1\""))
        #expect(xml.contains("sort=\"0\"") && xml.contains("autoFilter=\"0\""), "an allowed action is written as 0")
        #expect(xml.contains("selectLockedCells=\"1\""), "a forbidden action is written as 1")
        #expect(xml.contains("objects=\"1\""))
        #expect(!xml.contains("formatCells="), "the format's own default needs no attribute")

        let again = try Workbook(data: data).sheets[0]
        #expect(again.protection == p)
        #expect(again.protection.passwordMatches("secret") && !again.protection.passwordMatches("other"))
        #expect(again.style("B1").protection.locked == false)
    }

    /// The modern hash against an independent implementation: the three vectors were computed with Python's
    /// hashlib (same scheme, ECMA-376 §18.2.29 — salt ‖ UTF-16LE, then LE32(0-based iterator) appended each
    /// round), so a typo in either implementation cannot agree by accident. Salt is the fixed bytes 00…0F.
    @Test(arguments: [
        ("secret", 10, "CoBj8C4LJFOzosCJXdhEU4RdNsPlIhFCwkr+U7x3wbUjL+uH1qt3FIP83qh0VJlKuokE7RJwMheXqYN4Yc1sdQ=="),
        ("secret", 100_000, "M5SOVnbQG4SHyBnRVAYzAx8mPtxyyzMuWxcMv7tkyFO3MBXX9OJjklwPglNHdoHVkKPm4MPfUblqHmAsXfF5HA=="),
        ("秘密", 100_000, "Y/aSu3++rha+5yY9c209QtwU6jV7J3dpXK4s/Xn1tNi5PWZwTg5gUyE8oIl6FxiKa+EFtQrxvqQzNSIqKMMgKw==")
    ])
    func theModernHashMatchesTheIndependentReference(_ password: String, _ spinCount: Int, _ expected: String) {
        let salt = Data((0..<16).map { UInt8($0) })
        #expect(ModernPasswordHash.hash(password, salt: salt, spinCount: spinCount).base64EncodedString() == expected)
    }

    /// A modern password survives the file: all four attributes round-trip, the stored hash verifies, and the
    /// legacy hash is untouched by setting it.
    @Test func modernPasswordRoundTrips() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        var p = SheetProtection.on
        p.setPassword("legacy")                      // both schemes may coexist, as in Excel's own files
        p.setModernPassword("secret", spinCount: 10) // small count keeps the test fast
        wb.sheets[0].protection = p
        #expect(p.algorithmName == "SHA-512" && p.spinCount == 10 && p.saltValue != nil && p.hashValue != nil)

        let again = try Workbook(data: try wb.data(as: .xlsx)).sheets[0].protection
        #expect(again == p)
        #expect(again.modernPasswordMatches("secret") && !again.modernPasswordMatches("other"))
        #expect(again.passwordMatches("legacy"), "setting the modern password must not touch the legacy hash")

        var cleared = p
        cleared.setModernPassword(nil)
        #expect(cleared.algorithmName == nil && cleared.hashValue == nil && cleared.saltValue == nil && cleared.spinCount == nil)
    }

    /// Two calls draw two different salts, so equal passwords produce unequal files — and both still verify.
    @Test func modernPasswordSaltsAreRandom() {
        var a = SheetProtection.on, b = SheetProtection.on
        a.setModernPassword("same", spinCount: 10)
        b.setModernPassword("same", spinCount: 10)
        #expect(a.saltValue != b.saltValue && a.hashValue != b.hashValue)
        #expect(a.modernPasswordMatches("same") && b.modernPasswordMatches("same"))
    }

    /// Workbook protection and a protected range carry the same scheme.
    @Test func modernPasswordOnWorkbookAndRange() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.protection.lockStructure = true
        wb.protection.setModernPassword("book", spinCount: 10)
        var range = ProtectedRange(name: "window", "B2:C3")!
        range.setModernPassword("range", spinCount: 10)
        wb.sheets[0].protectedRanges = [range]

        let data = try wb.data(as: .xlsx)
        #expect(try Package.part("xl/workbook.xml", of: data).contains("workbookAlgorithmName=\"SHA-512\""))
        let again = try Workbook(data: data)
        #expect(again.protection.modernPasswordMatches("book"))
        #expect(again.sheets[0].protectedRanges.first?.modernPasswordMatches("range") == true)
    }

    /// The probe workbooks the real-Excel judge opens (`Tests/ExcelParity/verify_with_excel_app.py`, spec
    /// Appendix B.31). Each carries the **modern hash only** — a legacy `password=` alongside it would leave the
    /// judge unable to say which of the two Excel actually checked.
    @Test func writesTheProtectionProbeWorkbooks() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftsheets-protection-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        func sheetProbe(_ name: String, password: String, text: String) throws {
            var wb = Workbook()
            wb.sheets[0].name = "Locked"
            wb.sheets[0]["A1"] = CellValue.text(text)
            var p = SheetProtection.on
            p.setModernPassword(password)                    // default spin count: what Excel itself writes
            wb.sheets[0].protection = p
            let data = try wb.data(as: .xlsx)
            let xml = try Package.part("xl/worksheets/sheet1.xml", of: data)
            #expect(xml.contains("algorithmName=\"SHA-512\"") && !xml.contains(" password=\""),
                    "the probe must carry the modern hash and no legacy one")
            try data.write(to: dir.appendingPathComponent(name))
        }
        try sheetProbe("protect-ascii.xlsx", password: "secret", text: "この用紙は保護されています")
        try sheetProbe("protect-japanese.xlsx", password: "秘密", text: "合言葉は日本語")

        var wb = Workbook()
        wb.sheets[0]["A1"] = CellValue.text("ブックの構造が保護されています")
        wb.protection.lockStructure = true
        wb.protection.setModernPassword("book")
        let data = try wb.data(as: .xlsx)
        let xml = try Package.part("xl/workbook.xml", of: data)
        #expect(xml.contains("workbookAlgorithmName=\"SHA-512\"") && !xml.contains("workbookPassword=\""))
        try data.write(to: dir.appendingPathComponent("protect-workbook.xlsx"))
    }

    /// A sheet with no protection writes no element.
    @Test func noProtectionNoElement() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        #expect(try !Package.part("xl/worksheets/sheet1.xml", of: try wb.data(as: .xlsx)).contains("sheetProtection"))
    }

    // openpyxl: workbook/tests/test_protection.py::TestWorkbookProtection::test_ctor
    // openpyxl: workbook/tests/test_protection.py::TestWorkbookProtection::test_ctor_with_passwords
    // openpyxl: workbook/tests/test_protection.py::TestWorkbookProtection::test_from_xml
    @Test func workbookProtectionRoundTrips() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.protection.lockStructure = true
        wb.protection.lockWindows = true
        wb.protection.setPassword("secret")
        let data = try wb.data(as: .xlsx)
        let xml = try Package.part("xl/workbook.xml", of: data)
        #expect(xml.contains("<workbookProtection") && xml.contains("workbookPassword=\"DAA7\""))
        #expect(xml.contains("lockStructure=\"1\"") && xml.contains("lockWindows=\"1\""))
        // schema order: workbookPr, workbookProtection, bookViews, sheets
        let order = ["<workbookPr", "<workbookProtection", "<bookViews", "<sheets"]
        let positions = order.map { xml.range(of: $0)!.lowerBound }
        #expect(positions == positions.sorted())

        let again = try Workbook(data: data)
        #expect(again.protection == wb.protection && again.protection.passwordMatches("secret"))
    }

    @Test func protectedRangesRoundTrip() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.sheets[0].protection = .on
        var range = ProtectedRange(name: "入力欄", "B2:D9")!
        range.setPassword("secret")
        wb.sheets[0].protectedRanges = [range]
        let data = try wb.data(as: .xlsx)
        let xml = try Package.part("xl/worksheets/sheet1.xml", of: data)
        #expect(xml.contains("<protectedRange password=\"DAA7\" sqref=\"B2:D9\" name=\"入力欄\"/>"))
        // schema order: sheetProtection then protectedRanges
        #expect(xml.range(of: "<sheetProtection")!.lowerBound < xml.range(of: "<protectedRanges")!.lowerBound)
        #expect(try Workbook(data: data).sheets[0].protectedRanges == [range])
    }

    /// A modern hash written by Excel 2010 or later is carried through untouched — SwiftSheets does not compute
    /// new ones, but it must not lose the ones it finds.
    @Test func aModernHashIsCarriedThrough() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        var p = SheetProtection.on
        p.algorithmName = "SHA-512"
        p.hashValue = "Zm9vYmFy"
        p.saltValue = "c2FsdA=="
        p.spinCount = 100_000
        wb.sheets[0].protection = p
        let data = try wb.data(as: .xlsx)
        #expect(try Package.part("xl/worksheets/sheet1.xml", of: data).contains("algorithmName=\"SHA-512\" hashValue=\"Zm9vYmFy\" saltValue=\"c2FsdA==\" spinCount=\"100000\""))
        #expect(try Workbook(data: data).sheets[0].protection == p)
    }

    // openpyxl: worksheet/tests/test_scenario.py::TestScenario::test_ctor
    // openpyxl: worksheet/tests/test_scenario.py::TestScenario::test_from_xml
    // openpyxl: worksheet/tests/test_scenario.py::TestScenarios::test_ctor
    // openpyxl: worksheet/tests/test_scenario.py::TestScenarios::test_from_xml
    // openpyxl: worksheet/tests/test_scenario.py::TestInputCells::test_ctor
    // openpyxl: worksheet/tests/test_scenario.py::TestInputCells::test_from_xml
    @Test func scenariosRoundTrip() throws {
        var wb = Workbook()
        var ws = wb.sheets[0]
        ws["B1"] = 100; ws["B2"] = .number(0.05)
        ws.scenarios = ScenarioList([
            Scenario(name: "強気", cells: [Scenario.InputCell("B1", "150")!, Scenario.InputCell("B2", "0.08")!],
                     user: "南部", comment: "上振れ"),
            Scenario(name: "弱気", cells: [Scenario.InputCell("B1", "60")!], locked: true, hidden: true),
        ], current: 0, shown: 0)
        wb.sheets[0] = ws

        let data = try wb.data(as: .xlsx)
        let xml = try Package.part("xl/worksheets/sheet1.xml", of: data)
        #expect(xml.contains("<scenarios current=\"0\" show=\"0\" sqref=\"B1 B2\">"))
        #expect(xml.contains("<scenario name=\"強気\" count=\"2\" user=\"南部\" comment=\"上振れ\">"))
        #expect(xml.contains("<inputCells r=\"B1\" val=\"150\"/>"))
        #expect(xml.contains("<scenario name=\"弱気\" locked=\"1\" hidden=\"1\" count=\"1\">"))

        let again = try Workbook(data: data).sheets[0]
        #expect(again.scenarios.scenarios == ws.scenarios.scenarios)
        #expect(again.scenarios.current == 0 && again.scenarios.shown == 0)
        #expect(again.scenarios["強気"]?.cells.count == 2)
        #expect(again.scenarios.ranges == MultiCellRange("B1 B2"))
    }

    /// Converting to a format without protection or scenarios says so.
    @Test func odsReportsTheLoss() throws {
        var wb = Workbook()
        wb.sheets[0]["A1"] = 1
        wb.sheets[0].protection = .on
        wb.sheets[0].scenarios = [Scenario(name: "強気", cells: [Scenario.InputCell("A1", "2")!])]
        let result = try wb.write(as: .ods)
        #expect(result.warnings.contains { $0.message.contains("scenario") })
    }
}
