import Foundation
import Testing
@testable import SheetCore
@testable import SheetODS
import SwiftSheets

/// The other direction of the format comparison: what **OpenDocument has and OOXML has not** (spec Appendix B.17).
///
/// The element and attribute names come from the OASIS ODF 1.3 RelaxNG schema, and each test checks the same three
/// things: the writer emits what the schema asks for, our own reader takes it back unchanged, and — where
/// LibreOffice is installed — LibreOffice re-saves the file with the element still in it, which is the evidence
/// that a real application understood it.
@Suite(.serialized) struct ODFOnlyFeatureTests {
    static let hasLibreOffice = FileManager.default.fileExists(atPath: ODSCodecTests.soffice)
    static let tmp: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftSheetsODFOnly", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// A workbook using only what ODF has and OOXML has not.
    static func workbook() -> Workbook {
        var wb = Workbook()
        wb.sheets[0].name = "Data"
        var d = wb.sheets[0]
        d.append([CellValue.text("Region"), .text("Sales")])
        d.append([CellValue.text("East"), .integer(100)])
        d.append([CellValue.text("West"), .integer(200)])
        d["D1"] = Formula("=SUM(B2:B3)")
        d["E1"] = .number(Decimal(string: "1234.5")!)
        d.style("E1") { $0.numberFormat = "[$¥-411]#,##0.00" }
        d.table.detective[CellRef("D1")!] = CellDetective(
            highlighted: [CellDetective.HighlightedRange(range: CellRange("Data!B2:B3"), direction: .fromSameTable)],
            operations: [CellDetective.Operation(.tracePrecedents, index: 0)])
        wb.sheets[0] = d

        wb.epoch = .mac1904
        wb.calculationSettings.caseSensitive = true
        wb.calculationSettings.useRegularExpressions = true
        wb.calculationSettings.useWildcards = false
        wb.calculationSettings.searchCriteriaMustApplyToWholeCell = false
        wb.calculationSettings.precisionAsShown = true
        wb.calculationSettings.nullYear = 1930
        wb.calculationSettings.iterationEnabled = true
        wb.calculationSettings.iterationSteps = 42
        wb.calculationSettings.iterationMaximumDifference = 0.0005
        wb.labelRanges = [LabelRange(labels: CellRange("Data!A1:B1")!, data: CellRange("Data!A2:B3")!, orientation: .column)]
        wb.consolidation = Consolidation(function: .sum, sources: [CellRange("Data!A1:B3")!],
                                         target: CellRef("G1")!, targetSheet: "Data",
                                         useLabels: .both, linkToSourceData: true)
        return wb
    }

    static func contentXML(_ data: Data) throws -> String { try Package.part("content.xml", of: data) }

    /// Everything ODF-only survives a write and a read back, with nothing reported lost.
    @Test func everythingODFOnlyRoundTrips() throws {
        let wb = Self.workbook()
        let result = try ODSCodec.write(wb)
        #expect(result.warnings.isEmpty, Comment(rawValue: "\(result.warnings.map(\.message))"))
        let back = try ODSCodec.read(result.data).workbook

        #expect(back.epoch == .mac1904, "the date origin is table:null-date")
        #expect(back.calculationSettings == wb.calculationSettings)
        #expect(back.labelRanges == wb.labelRanges)
        #expect(back.consolidation == wb.consolidation)
        #expect(back.sheets[0].table.detective == wb.sheets[0].table.detective)
        // the currency survives as a currency; Excel's locale tag (`-411`) has no ODF equivalent and normalises away
        let money = back.sheets[0].style("E1").numberFormat
        #expect(money.contains("¥") && money.contains("#,##0.00"), Comment(rawValue: money))
        #expect(try ODSCodec.read(try ODSCodec.write(back).data).workbook.sheets[0].style("E1").numberFormat == money,
                "and a second trip changes nothing more")
    }

    /// The shapes the ODF 1.3 schema asks for.
    @Test func theXMLIsTheShapeTheSchemaAsksFor() throws {
        let xml = try Self.contentXML(try ODSCodec.write(Self.workbook()).data)
        // §9.4.1 — before the tables, with the origin and the iteration inside it
        #expect(xml.contains(#"table:case-sensitive="true""#))
        #expect(xml.contains(#"table:use-regular-expressions="true""#))
        #expect(xml.contains(#"table:use-wildcards="false""#))
        #expect(xml.contains(#"table:search-criteria-must-apply-to-whole-cell="false""#))
        #expect(xml.contains(#"table:null-year="1930""#))
        #expect(xml.contains(#"<table:null-date table:value-type="date" table:date-value="1904-01-01"/>"#))
        #expect(xml.contains(#"<table:iteration table:status="enable" table:steps="42""#))
        // §9.4.9 — the headings a formula may name
        #expect(xml.contains(#"<table:label-range table:label-cell-range-address="Data.A1:Data.B1""#))
        #expect(xml.contains(#"table:orientation="column""#))
        // §9.7 — the stored consolidation
        #expect(xml.contains(#"<table:consolidation table:function="sum""#))
        #expect(xml.contains(#"table:target-cell-address="Data.G1""#))
        #expect(xml.contains(#"table:use-labels="both""#))
        // §9.3.2 — the detective's arrows
        #expect(xml.contains(#"<table:detective>"#))
        #expect(xml.contains(#"table:direction="from-same-table""#))
        #expect(xml.contains(#"<table:operation table:name="trace-precedents" table:index="0"/>"#))
        // a cell that knows it holds money, which OOXML has no place for
        #expect(xml.contains(#"office:value-type="currency" office:currency="¥""#))
        #expect(xml.contains("<number:currency-symbol>¥</number:currency-symbol>"))
        // the calculation settings come first, then the validations, then the label ranges (§9.4 order)
        let settings = try #require(xml.range(of: "<table:calculation-settings"))
        let labels = try #require(xml.range(of: "<table:label-ranges>"))
        let firstTable = try #require(xml.range(of: "<table:table "))
        #expect(settings.lowerBound < labels.lowerBound)
        #expect(labels.lowerBound < firstTable.lowerBound)
    }

    /// Written to a format that is not ODS, the ODF-only material is reported rather than dropped in silence.
    /// The warning comes from the facade, because the XLSX codec is not changed for ODF-only additions
    /// (Appendix B.17).
    @Test func otherFormatsSayTheyDropIt() throws {
        let wb = Self.workbook()
        for format in [SheetFormat.xlsx, .numbers, .csv] {
            let warnings = try wb.write(as: format).warnings
            #expect(warnings.contains { $0.message.contains("only OpenDocument has it") && $0.message.contains("label range") },
                    "\(format.rawValue) says the label ranges are gone")
            #expect(warnings.contains { $0.message.contains("consolidation") })
            #expect(warnings.contains { $0.message.contains("tracing arrows") })
            // one sentence per setting that is in force and would be read differently there (Appendix B.23) —
            // this workbook sets case sensitivity, regular expressions, wildcards, precision-as-shown and iteration
            let calc = warnings.filter { $0.message.contains("a calculation setting is dropped") }
            #expect(calc.count >= 4, Comment(rawValue: "\(format.rawValue): \(calc.map(\.message))"))
            #expect(calc.contains { $0.message.contains("regular expression") })
            #expect(calc.contains { $0.message.contains("circular reference") })
        }
        // …and ODS says nothing, because ODS keeps them
        #expect(try !wb.write(as: .ods).warnings.contains { $0.message.contains("only OpenDocument has it") })
    }

    /// A calculation setting earns a warning when the destination would **behave differently**, not when it merely
    /// differs from the model's own defaults (spec Appendix B.23).
    ///
    /// LibreOffice writes its own defaults into every ODS it saves, so the older test — "is this the default
    /// workbook's settings?" — reported a loss on every ODS conversion anyone ever made, whether or not a single
    /// formula would evaluate differently. A warning everybody sees every time is a warning nobody reads.
    @Test func aCalculationSettingIsReportedOnlyWhenItWouldChangeSomething() throws {
        func warnings(_ settings: CalculationSettings) throws -> [String] {
            var wb = Workbook()
            wb.sheets[0]["A1"] = "x"
            wb.calculationSettings = settings
            return try wb.write(as: .xlsx).warnings.map(\.message).filter { $0.contains("calculation setting") }
        }

        #expect(try warnings(CalculationSettings()).isEmpty, "a brand-new workbook has nothing to report")

        // exactly what LibreOffice 26.2 writes into every file it saves
        var libreOffice = CalculationSettings()
        libreOffice.automaticFindLabels = false
        libreOffice.searchCriteriaMustApplyToWholeCell = true
        libreOffice.useWildcards = true
        libreOffice.iterationEnabled = false
        libreOffice.iterationMaximumDifference = 0.0001
        let noise = try warnings(libreOffice)
        #expect(noise.count == 0, Comment(rawValue: "LibreOffice's own defaults are not a loss: \(noise)"))

        // …but a two-digit-year window that really is elsewhere is one sentence, naming both ends
        var window = libreOffice
        window.nullYear = 1950
        let reported = try warnings(window)
        #expect(reported.count == 1, Comment(rawValue: "\(reported)"))
        #expect(reported[0].contains("1950") && reported[0].contains("1930"), Comment(rawValue: reported[0]))

        // a setting that changes how this document's own formulas evaluate is always reported
        var regex = CalculationSettings()
        regex.useRegularExpressions = true
        #expect(try warnings(regex).count == 1)

        // the iteration detail stays quiet while iteration is off, and speaks once it is on
        var iterating = CalculationSettings()
        iterating.iterationSteps = 42
        #expect(try warnings(iterating).isEmpty, "a step count no engine will reach is not a loss")
        iterating.iterationEnabled = true
        #expect(try warnings(iterating).count == 2, "the switch and the step count")
    }

    /// A date origin ODF allows and the model cannot hold is read as the 1900 system, and says so.
    @Test func anUnusualDateOriginIsReported() throws {
        let plain = try ODSCodec.write(Workbook()).data
        let content = try Self.contentXML(plain).replacingOccurrences(
            of: "<office:body>",
            with: #"<table:calculation-settings><table:null-date table:date-value="1950-06-01"/></table:calculation-settings><office:body>"#)
        // the settings belong inside office:spreadsheet, so put them right after it opens
        let patched = try Package.repacking(plain, replacing: "content.xml", with: Data(
            content.replacingOccurrences(
                of: #"<table:calculation-settings><table:null-date table:date-value="1950-06-01"/></table:calculation-settings><office:body><office:spreadsheet>"#,
                with: #"<office:body><office:spreadsheet><table:calculation-settings><table:null-date table:date-value="1950-06-01"/></table:calculation-settings>"#).utf8))
        let result = try ODSCodec.read(patched)
        #expect(result.workbook.epoch == .windows1900)
        #expect(result.warnings.contains { $0.message.contains("1950-06-01") })
    }

    /// Material the file carried and the model has no word for is remembered and reported on the way out.
    @Test func unmodelledODFMaterialIsReported() throws {
        let plain = try ODSCodec.write(Workbook()).data
        let content = try Self.contentXML(plain).replacingOccurrences(
            of: "<office:spreadsheet>",
            with: "<office:spreadsheet><table:tracked-changes><text:tracked-changes/></table:tracked-changes>")
        let patched = try Package.repacking(plain, replacing: "content.xml", with: Data(content.utf8))
        let read = try ODSCodec.read(patched).workbook
        #expect(read.unmodelledODFFeatures.contains(.trackedChanges))
        #expect(try ODSCodec.write(read).warnings.contains { $0.message.contains("revision history") })
    }

    /// LibreOffice re-saves the file with every ODF-only element still in it — the evidence that it understood them.
    @Test func libreOfficeKeepsThemAll() throws {
        let data = try ODSCodec.write(Self.workbook()).data
        try withKnownIssue("LibreOffice is not installed", isIntermittent: false) {
            try #require(Self.hasLibreOffice)
            let url = Self.tmp.appendingPathComponent("odf-only.ods")
            try data.write(to: url)
            let out = Self.tmp.appendingPathComponent("out", isDirectory: true)
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ODSCodecTests.soffice)
            p.arguments = ["--headless", "--convert-to", "ods", "--outdir", out.path, url.path]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            let resaved = try Data(contentsOf: out.appendingPathComponent("odf-only.ods"))
            let xml = try Self.contentXML(resaved)
            for element in ["table:calculation-settings", "table:null-date", "table:iteration",
                            "table:label-range", "table:consolidation", "table:detective", "office:currency"] {
                #expect(xml.contains(element), Comment(rawValue: "LibreOffice kept \(element)"))
            }
            // and it reads back into the same model — for the part LibreOffice keeps. It overwrites four of the
            // calculation settings (case-sensitive, regular expressions, wildcards, the two-digit-year window) with
            // its own application settings on re-save, so those are checked against our own reader, not this one
            // (spec Appendix B.17).
            let back = try ODSCodec.read(resaved).workbook
            #expect(back.epoch == .mac1904)
            #expect(back.calculationSettings.precisionAsShown)
            #expect(!back.calculationSettings.searchCriteriaMustApplyToWholeCell)
            #expect(back.labelRanges.count == 1)
            #expect(back.consolidation?.function == .sum)
            #expect(back.sheets[0].table.detective.count == 1)
        } when: {
            !Self.hasLibreOffice
        }
    }
}
