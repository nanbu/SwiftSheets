import Foundation
import Testing
@testable import SheetCore
@testable import SheetCSV
@testable import SheetNumbers
@testable import SheetODS
@testable import SheetXLSX
import SwiftSheets

/// Spec §12, pillar 5: "malformed コーパス＋ランダム破壊入力でクラッシュ・無限ループ・メモリ爆発がないこと".
/// `MalformedInputTests` is the hand-written half — every case there is a crash that once happened. This is the
/// other half: take the real corpus and break it in every cheap way there is, thousands of times, from fixed seeds.
///
/// The assertion is deliberately weak, because the interesting failures are not assertion failures: a trap or a
/// hang takes the whole test process down, and that *is* the report. What is checked here is the contract's edge —
/// whatever comes back is a `SheetError`, never a Foundation error leaking from a layer below, and never a
/// workbook quietly assembled out of nonsense that then fails to write.
@Suite struct FuzzTests {
    static let seeds: [UInt64] = (ProcessInfo.processInfo.environment["SWIFTSHEETS_FUZZ_SEEDS"].map { $0.split(separator: ",").compactMap { UInt64($0) } }) ?? [1, 2, 3, 0x5417_5EED]

    /// Small files only: a fuzz round has to be cheap enough to run thousands of times in a `swift test`.
    static let corpus: [(name: String, data: Data)] = {
        let root = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        let wanted = ["date1904.xlsx", "styled.xlsx", "rph.xlsx", "openpyxl/reader/complex-styles.xlsx",
                      "openpyxl/packaging/hyperlink.xlsx", "preservation/with-vba.xlsm",
                      "ods/styled.ods", "numbers/test-1.numbers", "numbers/test-formats.numbers"]
        var out: [(String, Data)] = []
        for name in wanted {
            if let data = try? Data(contentsOf: root.appendingPathComponent(name)), data.count < 400_000 {
                out.append((name, data))
            }
        }
        // whatever of the above is missing, the generated minimum still exercises every reader
        out.append(("generated.xlsx", (try? Workbook(sheets: [sampleSheet()]).data(as: .xlsx)) ?? Data()))
        // three sheets, so that a mutant reaches the side-by-side read (spec Appendix B.41) with two broken parts at once
        out.append(("generated-3-sheets.xlsx", (try? Workbook(sheets: (1...3).map { i in var s = sampleSheet(); s.name = "S\(i)"; return s }).data(as: .xlsx)) ?? Data()))
        out.append(("generated.ods", (try? Workbook(sheets: [sampleSheet()]).data(as: .ods)) ?? Data()))
        out.append(("generated.numbers", (try? Workbook(sheets: [sampleSheet()]).data(as: .numbers)) ?? Data()))
        out.append(("generated.csv", Data("a,b,c\n1,2,\"x\ny\"\n".utf8)))
        return out.filter { !$0.1.isEmpty }
    }()

    /// A longer hunt on demand: `SWIFTSHEETS_FUZZ_ROUNDS=20000 swift test --filter Fuzz`. The default is what a
    /// `swift test` should pay for; the campaign is what you run when you have changed a reader.
    static func rounds(_ standard: Int) -> Int {
        ProcessInfo.processInfo.environment["SWIFTSHEETS_FUZZ_ROUNDS"].flatMap(Int.init) ?? standard
    }

    static func sampleSheet() -> Sheet {
        var s = Sheet(name: "S")
        s["A1"] = "text"; s["B1"] = 12; s["C1"] = .formula(FormulaExpr.parse("=B1*2"), cached: .integer(24))
        s.merge("A2:B3")
        return s
    }

    /// Every mutation a corrupted download, a truncated upload or a hostile sender can produce, in one place.
    static func mutate(_ data: Data, using rng: inout SeededGenerator) -> Data {
        var bytes = [UInt8](data)
        switch Int.random(in: 0..<7, using: &rng) {
        case 0:   // flip a handful of bytes
            for _ in 0..<Int.random(in: 1...16, using: &rng) where !bytes.isEmpty {
                bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
            }
        case 1:   // truncate
            bytes = Array(bytes.prefix(Int.random(in: 0...bytes.count, using: &rng)))
        case 2:   // chop out the middle
            guard bytes.count > 2 else { break }
            let a = Int.random(in: 0..<bytes.count, using: &rng), b = Int.random(in: 0..<bytes.count, using: &rng)
            bytes.removeSubrange(Swift.min(a, b)..<Swift.max(a, b))
        case 3:   // splice in a run of one byte — length fields love these
            guard !bytes.isEmpty else { break }
            let at = Int.random(in: 0..<bytes.count, using: &rng)
            bytes.insert(contentsOf: [UInt8](repeating: UInt8.random(in: 0...255, using: &rng),
                                            count: Int.random(in: 1...64, using: &rng)), at: at)
        case 4:   // set a 4-byte little-endian field to something enormous
            guard bytes.count > 4 else { break }
            let at = Int.random(in: 0...(bytes.count - 4), using: &rng)
            for k in 0..<4 { bytes[at + k] = 0xFF }
        case 5:   // zero a run
            guard !bytes.isEmpty else { break }
            let at = Int.random(in: 0..<bytes.count, using: &rng)
            for k in at..<Swift.min(bytes.count, at + Int.random(in: 1...128, using: &rng)) { bytes[k] = 0 }
        default:  // duplicate a slice (repeated ZIP headers, repeated IWA blocks)
            guard bytes.count > 2 else { break }
            let a = Int.random(in: 0..<bytes.count, using: &rng), b = Int.random(in: 0..<bytes.count, using: &rng)
            bytes.insert(contentsOf: bytes[Swift.min(a, b)..<Swift.max(a, b)], at: Swift.min(a, b))
        }
        return Data(bytes)
    }

    /// Byte flips in a deflate stream mostly die at the CRC, which tests the ZIP layer and nothing above it. This
    /// one unpacks the package, breaks one part's *content*, and packs it again — so the XML and IWA readers get
    /// the malformed input rather than the container.
    static func mutateInsidePackage(_ data: Data, using rng: inout SeededGenerator) -> Data? {
        guard let zip = try? ZipArchive(data: data), !zip.entries.isEmpty else { return nil }
        let names = zip.entries.keys.sorted()
        let victim = names[Int.random(in: 0..<names.count, using: &rng)]
        var writer = ZipWriter()
        for name in names {
            guard var part = try? zip.read(name) else { return nil }
            if name == victim { part = breakContent(part, using: &rng) }
            writer.add(name, part, stored: name == "mimetype")
        }
        return writer.finish()
    }

    /// The ways a part goes wrong that a parser has to survive: cut short, doubled, an attribute value replaced by
    /// something enormous, a tag left open.
    static func breakContent(_ part: Data, using rng: inout SeededGenerator) -> Data {
        switch Int.random(in: 0..<6, using: &rng) {
        case 0: return part.prefix(Int.random(in: 0...part.count, using: &rng))
        case 1: return part + part
        case 2: return Data()
        case 3:
            guard var text = String(data: part, encoding: .utf8) else { return mutate(part, using: &rng) }
            for needle in ["\"1\"", "\"A1\"", "\"0\"", "count=", "r="] where text.contains(needle) {
                text = text.replacingOccurrences(of: needle, with: needle.hasSuffix("=") ? needle + "\"99999999999999999999\" x" : "\"99999999999999999999\"")
                break
            }
            return Data(text.utf8)
        case 4:
            guard let text = String(data: part, encoding: .utf8), let cut = text.firstIndex(of: ">") else { return mutate(part, using: &rng) }
            return Data(String(text[..<cut]).utf8)      // an element that never closes
        default: return mutate(part, using: &rng)
        }
    }

    /// The facade, which is where a caller's file actually arrives.
    @Test(.timeLimit(.minutes(5)), arguments: seeds) func mutatedCorpusAlwaysLandsOnASheetError(_ seed: UInt64) throws {
        var rng = SeededGenerator(seed: seed)
        var opened = 0
        for round in 0..<Self.rounds(600) {
            let source = Self.corpus[Int.random(in: 0..<Self.corpus.count, using: &rng)]
            let mutant = Bool.random(using: &rng)
                ? Self.mutate(source.data, using: &rng)
                : (Self.mutateInsidePackage(source.data, using: &rng) ?? Self.mutate(source.data, using: &rng))
            do {
                let wb = try Workbook(data: mutant, options: ReadOptions(cellLimit: 50_000))
                opened += 1
                // a workbook we accepted must also survive being written back — the model must not hold values no
                // writer can express
                _ = try wb.data(as: SheetFormat.xlsx)
            } catch let error as SheetError {
                _ = error.description   // every case must be able to describe itself
            } catch {
                Issue.record(Comment(rawValue: "\(source.name) round \(round) seed \(seed): \(type(of: error)) — \(error)"))
            }
        }
        // if nothing ever opened, the mutations are too destructive to be testing the readers at all
        #expect(opened > 0, "seed \(seed): no mutant was ever readable")
    }

    /// …and each reader directly, so a mutant that no longer *detects* as its format still reaches the code that
    /// used to own it.
    @Test(.timeLimit(.minutes(5)), arguments: seeds) func mutantsFedStraightToEachCodec(_ seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        for round in 0..<Self.rounds(300) {
            let source = Self.corpus[Int.random(in: 0..<Self.corpus.count, using: &rng)]
            let mutant = Bool.random(using: &rng)
                ? Self.mutate(source.data, using: &rng)
                : (Self.mutateInsidePackage(source.data, using: &rng) ?? Self.mutate(source.data, using: &rng))
            for format in SheetFormat.allCases {
                // concurrency 4: an XLSX mutant's sheets are parsed side by side however small it is
                do { _ = try Workbook.read(mutant, format: format, options: ReadOptions(cellLimit: 50_000, concurrency: 4)) }
                catch is SheetError {}
                catch { Issue.record(Comment(rawValue: "\(source.name) as \(format) round \(round) seed \(seed): \(type(of: error)) — \(error)")) }
                // …and the row-by-row reader of the same format (spec Appendix B.40), which has its own index
                // (Numbers), its own body walk (ODS) and its own record slicing: a mutant must land on a SheetError
                // there too, never on a trap
                do {
                    let reader = try StreamingReader(data: mutant, format: format)
                    if let first = reader.sheetNames.first {
                        var rows = 0
                        try reader.forEachRow(inSheet: first, options: StreamingReadOptions(includeStyles: round % 2 == 0)) { _ in
                            rows += 1
                            if rows >= 2_000 { throw SheetError.invalidWorkbook("enough") }
                        }
                    }
                }
                catch is SheetError {}
                catch { Issue.record(Comment(rawValue: "\(source.name) streamed as \(format) round \(round) seed \(seed): \(type(of: error)) — \(error)")) }
            }
        }
    }
}
