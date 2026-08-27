import Foundation
import Testing
@testable import SheetCore
import SwiftSheets

/// Conversion between the formats, measured in both directions — the sweep behind
/// `docs/interoperability.html`.
///
/// `FormatSupportTests` asks what one write keeps. This suite asks the two questions that only a *conversion* can
/// answer: does every loss have a warning that names it, and does a document survive being saved more than once?
/// Both went unasked until 2026-08-27, and both had something to say (spec Appendix B.22).
@Suite struct CrossFormatConversionTests {
    static let formats: [SheetFormat] = [.xlsx, .ods, .numbers]

    /// Each feature of the published table, and the words the warning about it has to contain.
    ///
    /// Deliberately narrow: "table" would match the named-table warning as readily as the several-tables one, and a
    /// loose match is what lets a silent loss hide behind a warning about something else. A feature with no entry
    /// here is a feature no conversion is allowed to lose.
    static let namedBy: [String: String] = [
        "配列数式": "array formula",
        "グループ化": "grouping",
        "条件付き書式": "conditional format",
        "CF・カラースケール": "colorScale",
        "CF・データバー": "dataBar",
        "CF・アイコンセット": "iconSet",
        "入力規則": "data validation",
        "名前付きの表": "named table",
        "オートフィルタ": "auto-filter",
        "絞り込み条件": "auto-filter",
        "並べ替えの記録": "auto-filter",
        "ピボット表": "pivot table",
        "シート保護": "sheet protection",
        "保護範囲": "protected range",
        "シナリオ": "scenario",
        "印刷・ヘッダフッタ": "print setup",
        "印刷・向き": "print setup",
        "印刷・範囲": "print setup",
        "印刷・タイトル行": "print setup",
        "改ページ": "print setup",
        "タブ色": "tab colour",
        "定義名・ブック": "defined name",
        "定義名・シート": "defined name",
        "ブック保護": "workbook protection",
        "文書の自由項目": "custom document propert",
        "隠しシート": "hidden sheet",
        "セルの制御": "cell control",
        "株価・為替の関数": "fetches live data",
        "1シート複数テーブル": "other table(s) not written",
        "ラベル範囲": "label range",
        "統合の定義": "consolidation",
        "探偵の矢印": "tracing arrow",
        "計算設定": "a calculation setting is dropped",
    ]

    /// A real file of each format, made from the one workbook that carries everything the model can say.
    static func source(_ format: SheetFormat) throws -> Workbook {
        try Workbook(data: try FormatSupportTests.kitchenSink().write(as: format).data)
    }

    /// Nothing is dropped in silence — in **every** direction, not only out of a fresh model.
    ///
    /// The source is a document that has already been through the format once, so what is measured is the
    /// conversion a user actually performs: open this file, save it as that.
    @Test(arguments: formats, formats)
    func everyLossIsNamedByItsOwnWarning(_ from: SheetFormat, _ to: SheetFormat) throws {
        let source = try Self.source(from)
        let before = FormatSupportTests.profile(of: source)
        let written = try source.write(as: to)
        let after = FormatSupportTests.profile(of: try Workbook(data: written.data))

        for (feature, wasThere) in before.sorted(by: { $0.key < $1.key }) where wasThere && !(after[feature] ?? false) {
            guard let word = Self.namedBy[feature] else {
                Issue.record("\(from.rawValue) → \(to.rawValue): \(feature) was lost, and no conversion is allowed to lose it")
                continue
            }
            #expect(written.warnings.contains { $0.message.contains(word) },
                    Comment(rawValue: """
                        \(from.rawValue) → \(to.rawValue): \(feature) was lost in silence — no warning contains "\(word)".
                        warnings: \(written.warnings.map(\.message))
                        """))
        }
    }

    /// Saving twice is not saving once twice over.
    ///
    /// A writer that emits an attribute of its own **and** puts back the source file's copy of the same attribute
    /// makes a part that is not well-formed XML; the file only breaks on the second write, which is why one round
    /// trip never showed it. Three generations, every part parsed, and nothing may fall out along the way.
    @Test(arguments: formats)
    func threeGenerationsStayWellFormedAndKeepEverything(_ format: SheetFormat) throws {
        var workbook = try Self.source(format)
        var previous = FormatSupportTests.profile(of: workbook)
        for generation in 2...4 {
            let written = try workbook.write(as: format)
            let package = try ZipInspection(data: written.data)
            for name in package.entryNames where name.hasSuffix(".xml") || name.hasSuffix(".rels") {
                guard let bytes = package.entry(named: name) else { continue }
                let parser = XMLParser(data: bytes)
                let delegate = WellFormedness()          // XMLParser holds its delegate weakly
                parser.delegate = delegate
                #expect(parser.parse(), Comment(rawValue: """
                    \(format.rawValue) generation \(generation): \(name) is not well-formed XML \
                    (\(parser.parserError.map { "\($0)" } ?? "unknown")) — an application would refuse the file
                    """))
            }
            let read = try Workbook(data: written.data)
            let now = FormatSupportTests.profile(of: read)
            let lost = previous.filter { $0.value && !(now[$0.key] ?? false) }.keys.sorted()
            #expect(lost.isEmpty, Comment(rawValue: """
                \(format.rawValue) generation \(generation) lost \(lost) that generation \(generation - 1) still had \
                — write warnings: \(written.warnings.map(\.message)), read warnings: \(read.readWarnings.map(\.message))
                """))
            previous = now
            workbook = read
        }
    }

    /// The regression behind the generation test, stated on its own so its failure names the cause.
    @Test func aPivotTableSurvivesBeingSavedTwice() throws {
        let once = try Self.source(.xlsx)
        #expect(once.sheets["Pivot"]?.pivotTables.count == 1)
        let twice = try Workbook(data: try once.write(as: .xlsx).data)
        #expect(twice.sheets["Pivot"]?.pivotTables.count == 1, "the pivot table did not survive a second write")
        let second = try once.write(as: .xlsx).data
        for part in ["xl/pivotTables/pivotTable1.xml", "xl/pivotCache/pivotCacheDefinition1.xml"] {
            let parser = XMLParser(data: Data(try Package.part(part, of: second).utf8))
            let delegate = WellFormedness()
            parser.delegate = delegate
            #expect(parser.parse(), Comment(rawValue: """
                \(part) is not well-formed after a second write \
                (\(parser.parserError.map { "\($0)" } ?? "unknown")) — the writer put an attribute back that it \
                had already written itself
                """))
        }
    }

    /// A macro loss says so wherever it happens: the subject is what makes `WriteResult.suggest` name .xlsm rather
    /// than a format that loses the macros just as thoroughly.
    @Test(arguments: [SheetFormat.xlsx, .ods, .numbers])
    func aDroppedVBAProjectIsAlwaysAMacroLoss(_ target: SheetFormat) throws {
        let url = Bundle.module.resourceURL!.appending(path: "Fixtures/preservation/with-vba.xlsm")
        let workbook = try Workbook(data: try Data(contentsOf: url))
        #expect(workbook.preserved.hasVBAProject)
        let written = try workbook.write(as: target)
        let macros = written.warnings.filter { $0.subject == .macros }
        #expect(macros.count == 1, Comment(rawValue: "\(target.rawValue): \(written.warnings.map(\.message))"))
        #expect(written.suggestion?.format == .xlsm, "the way out of a macro loss is .xlsm, not \(written.suggestion?.format.rawValue ?? "nothing")")
    }

    /// `Workbook.convert` is the one call that never hands back the workbook, so the warnings the *read* made have
    /// nowhere else to surface. It used to answer with the write's warnings alone: a Numbers document whose chart
    /// and cell controls the reader had named came back saying nothing at all (spec Appendix B.23).
    @Test func convertAnswersWithBothHalvesOfTheTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SwiftSheetsConvert-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appending(path: "canvas.numbers")
        try Data(contentsOf: Bundle.module.resourceURL!.appending(path: "Fixtures/numbers/chart-and-control-15.numbers"))
            .write(to: source)
        let read = try Workbook.read(contentsOf: source)
        // one warning: the chart. The document's pop-up menu is read as a validation, not warned about.
        #expect(read.warnings.count == 1, Comment(rawValue: "\(read.warnings.map(\.message))"))

        let converted = try Workbook.convert(source, to: .xlsx, output: directory.appending(path: "canvas.xlsx"))
        for warning in read.warnings {
            #expect(converted.warnings.contains(warning), Comment(rawValue: """
                convert() lost the read's warning "\(warning.message)" — it is the only place a caller could have seen it.
                convert() said: \(converted.warnings.map(\.message))
                """))
        }
        #expect(converted.warnings.prefix(read.warnings.count).elementsEqual(read.warnings),
                "the trip is reported in the order it was made: reading first")
    }

    /// Keeping the macros needs no conversion at all.
    @Test func macrosSurviveTheirOwnFormat() throws {
        let url = Bundle.module.resourceURL!.appending(path: "Fixtures/preservation/with-vba.xlsm")
        let written = try Workbook(data: try Data(contentsOf: url)).write(as: .xlsm)
        #expect(written.warnings.filter { $0.subject == .macros }.isEmpty)
        #expect(try Workbook(data: written.data).preserved.hasVBAProject)
    }
}

/// XMLParser reports a malformed document by failing `parse()`; nothing else is needed from the delegate.
private final class WellFormedness: NSObject, XMLParserDelegate {}
