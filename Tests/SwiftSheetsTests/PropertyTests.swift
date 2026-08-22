import Foundation
import Testing
@testable import SheetCore
@testable import SheetODS

/// Spec §12: "プロパティテスト — A1 ⇄ (row, col) 変換の全単射性、RLE 圧縮展開の対称性、数式 parse → emit → parse の
/// 不動点性をランダム入力で検証する". Appendix B.6 recorded these as the one part of the test strategy still to do:
/// the fixed case lists were there, the random generator was not.
///
/// Random, but never flaky: every generator is driven by `SeededGenerator` from a constant seed, so a failure is
/// reproducible from the message alone. Widening the search means adding seeds, not re-running and hoping.
@Suite struct PropertyTests {
    static let seeds: [UInt64] = [0x5417_5EED, 1, 2, 3, 0xDEADBEEF, 0x0123456789ABCDEF]

    // MARK: - A1 ⇄ (row, col)

    @Test(arguments: seeds) func a1AndIntegerCoordinatesAreABijection(_ seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        for _ in 0..<2_000 {
            let ref = CellRef(row: Int.random(in: 0...CellRef.maxRow, using: &rng),
                              col: Int.random(in: 0...CellRef.maxCol, using: &rng))
            #expect(CellRef(ref.a1) == ref, "\(ref.row),\(ref.col) → \(ref.a1)")
            #expect(CellRef(ref.absoluteA1) == ref, "\(ref.absoluteA1)")
            #expect(CellRef(ref.a1.lowercased()) == ref, "\(ref.a1.lowercased())")
            #expect(CellRef.columnIndex(ref.columnName) == ref.col, "\(ref.columnName)")
            // and the other way round: the name is the *only* spelling of that column
            #expect(CellRef.columnName(ref.col) == ref.columnName)
        }
    }

    /// Every column index the A1 parser accepts, exhaustively — a bijection claim over 18,278 values is cheap
    /// enough to prove rather than sample.
    @Test func columnNamesAreBijectiveOverTheWholeRange() {
        var seen = Set<String>()
        for col in 0...CellRef.maxParsedCol {
            let name = CellRef.columnName(col)
            #expect(seen.insert(name).inserted, "\(name) names two columns")
            #expect(CellRef.columnIndex(name) == col, "\(name)")
        }
        #expect(CellRef.columnName(CellRef.maxParsedCol) == "ZZZ")
        #expect(CellRef.columnIndex("AAAA") == nil)   // four letters is past the parser's range, not a wrap-around
    }

    // MARK: - ODS run-length compression

    /// The writer folds repeated rows and cells into `number-*-repeated`, the reader expands them. Neither is
    /// interesting on its own; what has to hold is that they are inverse — including at the edges the fixed tests
    /// keep hitting: a run that ends the row, a run of blanks, a single cell after a long gap.
    @Test(arguments: seeds) func runLengthFoldingAndExpansionAreInverse(_ seed: UInt64) throws {
        var rng = SeededGenerator(seed: seed)
        var sheet = Sheet(name: "RLE")
        var expected: [CellRef: CellValue] = [:]
        var row = 0
        for _ in 0..<40 {
            row += Int.random(in: 0...3, using: &rng)          // sometimes skip whole rows
            var col = 0
            while col < 30 {
                let run = Int.random(in: 1...6, using: &rng)
                if Bool.random(using: &rng) {                   // a run of the same value…
                    let value: CellValue = Bool.random(using: &rng)
                        ? .integer(Int.random(in: -50...50, using: &rng))
                        : .text("v\(Int.random(in: 0...4, using: &rng))")
                    for i in 0..<run where col + i < 30 {
                        let ref = CellRef(row: row, col: col + i)
                        sheet[ref.row, ref.col] = value
                        expected[ref] = value
                    }
                }                                               // …or a run of blanks
                col += run
            }
        }
        var wb = Workbook(sheets: [sheet])
        wb.activeIndex = 0
        let written = try ODSCodec.write(wb)
        let read = try ODSCodec.read(written.data).workbook

        var found: [CellRef: CellValue] = [:]
        let table = read.sheets[0].tables[0]
        for r in 0...(table.extent?.maxRow ?? 0) {
            for c in 0...(table.extent?.maxCol ?? 0) {
                if let v = table[r, c] { found[CellRef(row: r, col: c)] = v }
            }
        }
        #expect(found == expected, "seed \(seed): \(found.count) cells back from \(expected.count)")
    }

    // MARK: - Formulas

    /// parse → emit → parse over generated trees, in both dialects. The fixed list in `FormulaTests` covers the
    /// shapes someone thought of; this covers the ones nobody did — nested precedence, sheet prefixes that need
    /// quoting, arrays inside calls, `%` under `^`.
    @Test(arguments: seeds) func generatedFormulasSurviveEmitAndReparse(_ seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        for _ in 0..<400 {
            let ast = FormulaGenerator.expression(depth: 3, using: &rng)
            for dialect in [SheetFormat.xlsx, .ods] {
                let text = ast.rendered(as: dialect)
                let reparsed = FormulaExpr.parse(text, dialect: dialect)
                #expect(reparsed == ast, "\(dialect): \(text)")
                // …and a second pass changes nothing, which is what "fixed point" actually claims
                #expect(FormulaExpr.parse(reparsed.rendered(as: dialect), dialect: dialect) == reparsed, "\(dialect): \(text)")
            }
        }
    }

    /// Random *text* — almost none of it a formula. The parser must never trap or hang on it, and whatever it does
    /// decide must be stable: parse(emit(parse(x))) == parse(x), even when the answer is `.unparsed`.
    @Test(arguments: seeds) func randomTextParsesToSomethingStable(_ seed: UInt64) {
        var rng = SeededGenerator(seed: seed)
        let alphabet = Array("ABC()[]{}:,;\"'!$%^&*+-/<>=@#. 1234'\\\n\t漢")
        for _ in 0..<1_500 {
            let text = String((0..<Int.random(in: 0...40, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
            let once = FormulaExpr.parse(text)
            let twice = FormulaExpr.parse(once.rendered(as: .xlsx))
            #expect(once == twice, "unstable: \(text.debugDescription) → \(once.rendered(as: .xlsx).debugDescription)")
        }
    }
}

/// SplitMix64 — eight lines, no state to get wrong, and identical on every machine. `SystemRandomNumberGenerator`
/// would make a failing seed unreportable.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Builds formula trees that a correct emitter must be able to write down unambiguously. What it will not generate
/// is itself a statement about the notation, not a gap in the parser: negative literals (`-2` is a negation of a
/// literal), a lone `.missing` argument (`SUM()` has no way to say "one omitted argument"), bare `.column` / `.row`
/// outside a range (`Sheet1!5` is not a reference in any dialect — it reads as a name), references inside array
/// constants (Excel allows literals only), and ragged arrays.
enum FormulaGenerator {
    static let functions = ["SUM", "IF", "COUNT", "VLOOKUP", "TEXT", "MAX", "ROUND"]
    static let errors = ["#REF!", "#VALUE!", "#DIV/0!", "#N/A", "#NAME?", "#NULL!", "#NUM!"]
    static let sheets: [String?] = [nil, "Sheet1", "集計", "My Sheet", "it's here", "Sheet-2"]
    static let operators: [FormulaOp] = [.add, .subtract, .multiply, .divide, .power, .concat,
                                         .equal, .notEqual, .less, .lessOrEqual, .greater, .greaterOrEqual]

    static func expression(depth: Int, using rng: inout SeededGenerator) -> FormulaExpr {
        if depth <= 0 { return scalar(using: &rng) }
        switch Int.random(in: 0..<11, using: &rng) {
        case 0, 1: return .binary(operators.randomElement(using: &rng)!, expression(depth: depth - 1, using: &rng),
                                  expression(depth: depth - 1, using: &rng))
        case 2: return .unary(Bool.random(using: &rng) ? .negate : .plus, expression(depth: depth - 1, using: &rng))
        case 3: return .unary(.percent, expression(depth: depth - 1, using: &rng))
        case 4: return call(depth: depth, using: &rng)
        case 5: return range(using: &rng)
        case 6: return array(using: &rng)
        case 7: return .binary(.union, reference(using: &rng), reference(using: &rng))
        // intersection: references and ranges only, which is the scope both dialects can spell (a name operand has
        // no OpenFormula form — `FormulaTests.intersectionOfNamesHasNoODSForm`)
        case 8: return .binary(.intersect, Bool.random(using: &rng) ? reference(using: &rng) : range(using: &rng),
                                           Bool.random(using: &rng) ? reference(using: &rng) : range(using: &rng))
        default: return scalar(using: &rng)
        }
    }

    /// `.missing` only where the text can actually say it: between two separators, never as the only argument.
    static func call(depth: Int, using rng: inout SeededGenerator) -> FormulaExpr {
        let count = Int.random(in: 1...3, using: &rng)
        let args = (0..<count).map { _ -> FormulaExpr in
            count > 1 && Int.random(in: 0..<8, using: &rng) == 0 ? .missing : expression(depth: depth - 1, using: &rng)
        }
        return .call(name: functions.randomElement(using: &rng)!, args: args.allSatisfy { $0 == .missing } ? [.number(1)] : args)
    }

    /// Rectangular, literals only — an array constant is data, not a reference.
    static func array(using rng: inout SeededGenerator) -> FormulaExpr {
        let width = Int.random(in: 1...3, using: &rng)
        return .array((0...Int.random(in: 0...1, using: &rng)).map { _ in (0..<width).map { _ in literal(using: &rng) } })
    }

    static func literal(using rng: inout SeededGenerator) -> FormulaExpr {
        switch Int.random(in: 0..<5, using: &rng) {
        case 0: return .number(Decimal(Int.random(in: 0...9_999, using: &rng)))
        case 1: return .number(Decimal(Int.random(in: 0...9_999, using: &rng)) / 4)   // 0.25 steps print exactly
        case 2: return .string(text(using: &rng))
        case 3: return .boolean(Bool.random(using: &rng))
        default: return .error(errors.randomElement(using: &rng)!)
        }
    }

    static func scalar(using rng: inout SeededGenerator) -> FormulaExpr {
        switch Int.random(in: 0..<8, using: &rng) {
        case 0...4: return literal(using: &rng)
        case 5: return .name("Name_\(Int.random(in: 0...99, using: &rng))", sheet: sheets.randomElement(using: &rng)!)
        default: return reference(using: &rng)
        }
    }

    static func reference(using rng: inout SeededGenerator) -> FormulaExpr {
        .ref(CellRef(row: Int.random(in: 0...CellRef.maxRow, using: &rng), col: Int.random(in: 0...CellRef.maxCol, using: &rng)),
             sheet: sheets.randomElement(using: &rng)!, absRow: Bool.random(using: &rng), absCol: Bool.random(using: &rng))
    }

    /// Both endpoints of a range name the same sheet — the text says it once, so the tree carries it twice.
    static func range(using rng: inout SeededGenerator) -> FormulaExpr {
        let sheet = sheets.randomElement(using: &rng)!
        func endpoint(_ kind: Int) -> FormulaExpr {
            switch kind {
            case 0: return .column(Int.random(in: 0...CellRef.maxCol, using: &rng), sheet: sheet, abs: Bool.random(using: &rng))
            case 1: return .row(Int.random(in: 0...CellRef.maxRow, using: &rng), sheet: sheet, abs: Bool.random(using: &rng))
            default: return .ref(CellRef(row: Int.random(in: 0...CellRef.maxRow, using: &rng), col: Int.random(in: 0...CellRef.maxCol, using: &rng)),
                                 sheet: sheet, absRow: Bool.random(using: &rng), absCol: Bool.random(using: &rng))
            }
        }
        let kind = Int.random(in: 0..<3, using: &rng)
        return .range(endpoint(kind), endpoint(kind))
    }

    static func text(using rng: inout SeededGenerator) -> String {
        let alphabet = Array("abcXYZ 0129\"'&<>日本語,;()")
        return String((0..<Int.random(in: 0...8, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
    }
}
