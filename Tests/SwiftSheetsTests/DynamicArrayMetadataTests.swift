import Foundation
import Testing
@testable import SheetCore
@testable import SheetXLSX
import SwiftSheets

@Suite struct DynamicArrayMetadataTests {
    private static let origin = CellRef("B2")!

    private static func workbook() -> Workbook {
        var workbook = Workbook()
        workbook.sheets[0]["A1"] = 3
        workbook.sheets[0]["B2"] = .formula(.parse("SEQUENCE(A1)"), cached: 1)
        workbook.sheets[0]["B3"] = 2
        workbook.sheets[0]["B4"] = 3
        workbook.sheets[0].table.arrayFormulas[origin] = CellRange("B2:B4")!
        workbook.sheets[0].table.dynamicArrayOrigins.insert(origin)
        return workbook
    }

    /// A synthetic package with relocated metadata, nontrivial indices, and unrelated metadata records.
    static func source(dynamic: String = "1", mixed: Bool = false, namespace: String = DynamicArrayMetadata.namespace,
                       uri: String = "{BDBB8CDC-FA1E-496E-A857-3C3F30C029C3}") throws -> Data {
        let data = try workbook().write(as: .xlsx).data
        let inspection = try ZipInspection(data: data)
        var writer = ZipWriter()
        for path in inspection.entryNames {
            var bytes = try #require(inspection.entry(named: path))
            var target = path
            if path == "xl/metadata.xml" {
                target = "xl/custom/array-metadata.xml"
                let xml = """
                <metadata xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:d="\(namespace)">
                  <metadataTypes count="2"><metadataType name="VENDOR"/><metadataType name="XLDAPR" cellMeta="1"/></metadataTypes>
                  <futureMetadata name="VENDOR" count="1"><bk><extLst><ext uri="vendor"><payload xmlns="urn:vendor" value="untouched"/></ext></extLst></bk></futureMetadata>
                  <futureMetadata name="XLDAPR" count="2"><bk/><bk><extLst><ext uri="\(uri)"><d:dynamicArrayProperties fDynamic="\(dynamic)" fCollapsed="0"/></ext></extLst></bk></futureMetadata>
                  <cellMetadata count="2"><bk><rc t="1" v="0"/></bk><bk><rc t="2" v="1"/>\(mixed ? "<rc t=\"1\" v=\"0\"/>" : "")</bk></cellMetadata>
                  <valueMetadata count="1"><bk><rc t="1" v="0"/></bk></valueMetadata>
                </metadata>
                """
                bytes = Data(xml.utf8)
            } else if path == "xl/_rels/workbook.xml.rels" || path == "[Content_Types].xml" {
                bytes = Data(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "metadata.xml", with: "custom/array-metadata.xml").utf8)
            } else if path == "xl/worksheets/sheet1.xml" {
                bytes = Data(String(decoding: bytes, as: UTF8.self)
                    .replacingOccurrences(of: "cm=\"1\"", with: "cm=\"2\" vm=\"1\"")
                    .replacingOccurrences(of: "<c r=\"A1\"", with: "<c r=\"A1\" cm=\"1\"").utf8)
            }
            writer.add(target, bytes)
        }
        return writer.finish()
    }

    @Test func newSpillWritesCanonicalMetadataAndLegacyArraysStayDistinct() throws {
        var workbook = Self.workbook()
        workbook.sheets[0]["D2"] = .formula(.parse("TRANSPOSE(A1:A2)"), cached: 3)
        workbook.sheets[0].table.arrayFormulas[CellRef("D2")!] = CellRange("D2:E2")!
        let data = try workbook.write(as: .xlsx).data
        let metadata = try Package.part("xl/metadata.xml", of: data)
        // Native Excel repaired the former uppercase output; B.114 requires the observed lowercase spelling.
        #expect(metadata.contains("uri=\"{bdbb8cdc-fa1e-496e-a857-3c3f30c029c3}\""))
        #expect(!metadata.contains("uri=\"{BDBB8CDC-FA1E-496E-A857-3C3F30C029C3}\""))
        #expect(metadata.contains("fDynamic=\"1\" fCollapsed=\"0\""))
        let reread = try Workbook(data: data)
        #expect(reread.sheets[0].table.arrayFormulas == workbook.sheets[0].table.arrayFormulas)
        #expect(reread.sheets[0].table.dynamicArrayOrigins == [Self.origin])
        let sheetXML = try Package.part("xl/worksheets/sheet1.xml", of: data)
        #expect(sheetXML.contains("r=\"B2\" cm=\"1\""))
        #expect(!sheetXML.contains("r=\"D2\" cm="))
    }

    @Test func relationshipAndBothIndexBasesAreResolvedWithoutChangingUnknownBytes() throws {
        let data = try Self.source()
        let workbook = try Workbook(data: data)
        #expect(workbook.sheets[0].table.dynamicArrayOrigins == [Self.origin])
        let output = try workbook.write(as: .xlsx).data
        let path = "xl/custom/array-metadata.xml"
        #expect(try ZipInspection(data: output).entry(named: path) == ZipInspection(data: data).entry(named: path))
        let sheet = try Package.part("xl/worksheets/sheet1.xml", of: output)
        #expect(sheet.contains("r=\"B2\" cm=\"2\" vm=\"1\""))
        #expect(sheet.contains("r=\"A1\" cm=\"1\""))
        #expect(try Workbook(data: output).sheets[0].table.dynamicArrayOrigins == [Self.origin])
    }

    @Test(arguments: ["{BDBB8CDC-FA1E-496E-A857-3C3F30C029C3}",
                      "{bdbb8cdc-fa1e-496e-a857-3c3f30c029c3}",
                      "{bDbB8cDc-Fa1E-496e-A857-3c3F30c029c3}"])
    func sourceURICaseVariantsRemainReadableAndBytePreserved(uri: String) throws {
        let source = try Self.source(uri: uri)
        let workbook = try Workbook(data: source)
        #expect(workbook.sheets[0].table.dynamicArrayOrigins == [Self.origin])
        let output = try workbook.write(as: .xlsx).data
        let path = "xl/custom/array-metadata.xml"
        #expect(try ZipInspection(data: output).entry(named: path) == ZipInspection(data: source).entry(named: path))
        #expect(try Package.part(path, of: output).contains("uri=\"\(uri)\""))
    }

    @Test(arguments: ["0", "false"])
    func aNonTrueFlagIsALegacyArray(flag: String) throws {
        let workbook = try Workbook(data: Self.source(dynamic: flag))
        #expect(workbook.sheets[0].table.arrayFormulas[Self.origin] == CellRange("B2:B4"))
        #expect(workbook.sheets[0].table.dynamicArrayOrigins.isEmpty)
    }

    @Test func aWrongNamespaceDoesNotEstablishDynamicSemantics() throws {
        let workbook = try Workbook(data: Self.source(namespace: "urn:unrelated"))
        #expect(workbook.sheets[0].table.dynamicArrayOrigins.isEmpty)
        #expect(workbook.readWarnings.contains { $0.context?.code == .dynamicArrayMetadata && $0.context?.preservation == .preserved })
    }

    @Test func anAbsentFlagIsLegacyAndAnInvalidIndexIsDiagnosed() throws {
        let data = try Self.source()
        let path = "xl/custom/array-metadata.xml"
        let metadata = try Package.part(path, of: data).replacingOccurrences(of: " fDynamic=\"1\"", with: "")
        let absent = try Package.repacking(data, replacing: path, with: Data(metadata.utf8))
        #expect(try Workbook(data: absent).sheets[0].table.dynamicArrayOrigins.isEmpty)
        let sheetPath = "xl/worksheets/sheet1.xml"
        let sheet = try Package.part(sheetPath, of: data).replacingOccurrences(of: "cm=\"2\"", with: "cm=\"999\"")
        let malformed = try Package.repacking(data, replacing: sheetPath, with: Data(sheet.utf8))
        let workbook = try Workbook(data: malformed)
        #expect(workbook.sheets[0].table.dynamicArrayOrigins.isEmpty)
        #expect(workbook.readWarnings.contains { $0.location == Self.origin && $0.context?.code == .dynamicArrayMetadata })
        #expect(try Package.part(sheetPath, of: workbook.write(as: .xlsx).data).contains("cm=\"999\""))
    }

    @Test func addingAnOriginReusesAPureBlockAndLeavesUnknownMetadataIntact() throws {
        let data = try Self.source()
        var workbook = try Workbook(data: data)
        workbook.sheets[0]["D2"] = .formula(.parse("SEQUENCE(2)"), cached: 1)
        workbook.sheets[0].table.arrayFormulas[CellRef("D2")!] = CellRange("D2:D3")!
        workbook.sheets[0].table.dynamicArrayOrigins.insert(CellRef("D2")!)
        let output = try workbook.write(as: .xlsx).data
        #expect(try ZipInspection(data: output).entry(named: "xl/custom/array-metadata.xml") == ZipInspection(data: data).entry(named: "xl/custom/array-metadata.xml"))
        #expect(try Workbook(data: output).sheets[0].table.dynamicArrayOrigins == [Self.origin, CellRef("D2")!])
    }

    @Test func changingAMixedBlockIsRefusedWhileAnUnchangedOneSurvives() throws {
        let data = try Self.source(mixed: true)
        var workbook = try Workbook(data: data)
        #expect(try Workbook(data: workbook.write(as: .xlsx).data).sheets[0].table.dynamicArrayOrigins == [Self.origin])
        workbook.sheets[0].table.dynamicArrayOrigins.remove(Self.origin)
        #expect(throws: SheetError.self) { try workbook.write(as: .xlsx) }
    }

    @Test func shrinkingASpillClearsOnlyFormerResultsAndKeepsFormatting() throws {
        var workbook = Self.workbook()
        workbook.sheets[0][cell: "B4"].font.bold = true
        workbook.sheets[0]["C4"] = 99
        workbook.sheets[0].table.arrayFormulas[Self.origin] = CellRange("B2:B3")!
        #expect(workbook.sheets[0]["B3"] == 2)
        #expect(workbook.sheets[0]["B4"] == nil)
        #expect(workbook.sheets[0][cell: "B4"].font.bold)
        #expect(workbook.sheets[0]["C4"] == 99)
        let reread = try Workbook(data: workbook.write(as: .xlsx).data)
        #expect(reread.sheets[0]["B4"] == nil)
        #expect(reread.sheets[0].table.arrayFormulas[Self.origin] == CellRange("B2:B3"))
    }

    @Test func rowAndColumnEditsMoveOriginsRangesAndOpaqueIndicesTogether() throws {
        var workbook = try Workbook(data: Self.source())
        workbook.sheets[0].insertRows(at: 2)
        workbook.sheets[0].insertColumns(at: 1)
        let origin = CellRef("C3")!
        #expect(workbook.sheets[0].table.dynamicArrayOrigins == [origin])
        #expect(workbook.sheets[0].table.arrayFormulas[origin] == CellRange("C3:C5"))
        let output = try workbook.write(as: .xlsx).data
        #expect(try Package.part("xl/worksheets/sheet1.xml", of: output).contains("r=\"C3\" cm=\"2\" vm=\"1\""))
        workbook.sheets[0].deleteRows(at: 4)
        #expect(workbook.sheets[0].table.arrayFormulas[origin] == CellRange("C3:C4"))
        workbook.sheets[0].deleteRows(at: 3)
        #expect(workbook.sheets[0].table.dynamicArrayOrigins.isEmpty)
        #expect(workbook.sheets[0].table.arrayFormulas.isEmpty)
        #expect(workbook.sheets[0]["C3"] == nil)
    }

    @Test func inconsistentPublicMetadataIsRejected() throws {
        var workbook = Workbook()
        workbook.sheets[0].table.dynamicArrayOrigins.insert(Self.origin)
        #expect(throws: SheetError.self) { try workbook.write(as: .xlsx) }
    }

    @Test func cachedValueReadingWritesValuesWithoutSpillMetadata() throws {
        let workbook = try Workbook(data: Self.source(), options: ReadOptions(formulaCells: .cachedValues))
        #expect(workbook.sheets[0].table.arrayFormulas.isEmpty)
        #expect(workbook.sheets[0].table.dynamicArrayOrigins.isEmpty)
        let output = try workbook.write(as: .xlsx).data
        let sheet = try Package.part("xl/worksheets/sheet1.xml", of: output)
        #expect(!sheet.contains("<f"))
        #expect(sheet.contains("r=\"B2\" vm=\"1\""))
        #expect(try Workbook(data: output).sheets[0]["B2"] == 1)
    }

    @Test func metadataOnlyCellsRemainAfterTheirVisibleValueIsCleared() throws {
        let data = try Self.source()
        let path = "xl/worksheets/sheet1.xml"
        let xml = try Package.part(path, of: data).replacingOccurrences(of: "</sheetData>", with: "<row r=\"20\"><c r=\"Z20\" cm=\"1\" vm=\"1\"/></row></sheetData>")
        var workbook = try Workbook(data: Package.repacking(data, replacing: path, with: Data(xml.utf8)))
        workbook.sheets[0]["Z20"] = nil
        workbook.sheets[0]["A1"] = nil
        let output = try workbook.write(as: .xlsx).data
        let sheet = try Package.part(path, of: output)
        #expect(sheet.contains("<c r=\"Z20\" cm=\"1\" vm=\"1\"/>"))
        #expect(sheet.contains("<c r=\"A1\" cm=\"1\"/>"))
        #expect(sheet.contains("<dimension ref=\"A1:Z20\"/>"))
    }

    @Test func excessiveMetadataNestingIsDiagnosedAndPreserved() throws {
        let data = try Self.source()
        let path = "xl/custom/array-metadata.xml"
        let xml = "<metadata xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
            + (0..<300).map { "<n xmlns:p\($0)=\"urn:\($0)\">" }.joined()
            + String(repeating: "</n>", count: 300) + "</metadata>"
        let bytes = Data(xml.utf8)
        #expect(throws: SheetError.self) { try DynamicArrayMetadata.read(bytes, part: path) }
        let workbook = try Workbook(data: Package.repacking(data, replacing: path, with: bytes))
        #expect(workbook.readWarnings.contains { $0.context?.code == .dynamicArrayMetadata && $0.context?.preservation == .preserved })
        #expect(try ZipInspection(data: workbook.write(as: .xlsx).data).entry(named: path) == bytes)
    }

    @Test func foreignUnknownMetadataCannotReuseAnUnrelatedWorkbooksEqualIndex() throws {
        let base = try Self.workbook().write(as: .xlsx).data
        let unknownMetadata = """
        <metadata xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <metadataTypes count="1"><metadataType name="VENDOR" cellMeta="1"/></metadataTypes>
          <futureMetadata name="VENDOR" count="1"><bk><extLst><ext uri="vendor"><payload xmlns="urn:vendor"/></ext></extLst></bk></futureMetadata>
          <cellMetadata count="1"><bk><rc t="1" v="0"/></bk></cellMetadata>
        </metadata>
        """
        let unknownSheet = """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" cm="1"><v>9</v></c></row></sheetData></worksheet>
        """
        let foreignData = try Package.repacking(
            Package.repacking(base, replacing: "xl/metadata.xml", with: Data(unknownMetadata.utf8)),
            replacing: "xl/worksheets/sheet1.xml", with: Data(unknownSheet.utf8))
        let foreign = try Workbook(data: foreignData)
        var destination = try Workbook(data: base)
        #expect(foreign.preserved.cellMetadataPath == destination.preserved.cellMetadataPath)
        #expect(foreign.sheets[0].table.xlsxCellMetadata[CellRef("A1")!]?.cell == "1")
        #expect(destination.sheets[0].table.xlsxCellMetadata[Self.origin]?.cell == "1")
        var imported = foreign.sheets[0]
        imported.name = "Imported"
        destination.sheets.append(imported)
        #expect(throws: SheetError.self) { try destination.write(as: .xlsx) }
        var newDestination = Workbook()
        newDestination.sheets.append(imported)
        #expect(throws: SheetError.self) { try newDestination.write(as: .xlsx) }
    }

    @Test func foreignPureDynamicMetadataIsReassignedAndSameWorkbookCopiesKeepUnknownBindings() throws {
        let foreign = try Workbook(data: Self.workbook().write(as: .xlsx).data)
        var destination = try Workbook(data: Self.source())
        var imported = foreign.sheets[0]
        imported.name = "Imported"
        destination.sheets.append(imported)
        let output = try destination.write(as: .xlsx).data
        let sheet = try Package.part("xl/worksheets/sheet2.xml", of: output)
        #expect(sheet.contains("r=\"B2\" cm=\"2\""))
        #expect(!sheet.contains("cm=\"1\""))
        #expect(try Workbook(data: output).sheets[1].table.dynamicArrayOrigins == [Self.origin])

        var copied = try Workbook(data: Self.source())
        let name = copied.sheets[0].name
        #expect(copied.duplicateSheet(named: name, as: "Copy") == 1)
        let copiedOutput = try copied.write(as: .xlsx).data
        let copiedXML = try Package.part("xl/worksheets/sheet2.xml", of: copiedOutput)
        #expect(copiedXML.contains("r=\"A1\" cm=\"1\""))
        #expect(copiedXML.contains("r=\"B2\" cm=\"2\" vm=\"1\""))
        #expect(try Workbook(data: copiedOutput).sheets[1].table.dynamicArrayOrigins == [Self.origin])
    }

    @Test func sourceIdentityDoesNotChangeWorkbookValueEquality() throws {
        let data = try Self.source()
        let first = try Workbook(data: data)
        let second = try Workbook(data: data)
        #expect(first == second)
        #expect(!first.preserved.cellMetadataSourceID.matches(second.preserved.cellMetadataSourceID))
        #expect(first.preserved.cellMetadataSourceID.matches(first.sheets[0].table.xlsxCellMetadataSourceID))
    }

    @Test func odsReportsItsFixedMatrixSubstitution() throws {
        let result = try Self.workbook().write(as: .ods)
        #expect(result.warnings.contains { $0.subject == .formulas && $0.message.contains("fixed matrix") })
        let workbook = try Workbook(data: result.data)
        #expect(workbook.sheets[0].table.arrayFormulas[Self.origin] == CellRange("B2:B4"))
        #expect(workbook.sheets[0].table.dynamicArrayOrigins.isEmpty)
    }
}
