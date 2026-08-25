import Foundation
import SheetCore

/// Numbers' conditional formats, which the schema calls a `TST.ConditionalStyleSetArchive` and Apple's Protobuf
/// describes only as far as `required int32 predicate_type` — an unnamed integer standing for a C enumeration
/// nobody outside Apple has the names of (spec Appendix B.16).
///
/// The values below were **observed, not guessed**. A workbook with one rule kind per column, each carrying a
/// parameter no other rule uses (11, 12, 13–14, 15–16, 17, 18, 19, 20, "pp", "qq", "rr", "ss"), was written as
/// `.xlsx`, imported by Numbers 15.3.1 and saved back as `.numbers`; each surviving rule was then matched to the
/// column that produced it **by its parameter**, so the mapping does not rest on the order the rules came out in
/// (Appendix B.18). Of twenty-five Excel rule kinds Numbers kept fourteen — the eight comparisons, the four text
/// rules, duplicate and unique. Colour scales, data bars, icon sets, top-n, above-average, blanks, errors, dates
/// and free formulas it dropped on import, which is Numbers saying it has no word for them.
enum NumbersConditional {
    /// Numbers' `predicate_type` → what the model calls the same rule.
    static let predicates: [Int: (kind: ConditionalFormattingRule.Kind, op: ConditionalFormattingRule.Operator?)] = [
        1: (.beginsWith, .beginsWith),
        2: (.endsWith, .endsWith),
        3: (.containsText, .containsText),
        4: (.notContainsText, .notContains),
        5: (.cellIs, .equal),
        6: (.cellIs, .notEqual),
        7: (.cellIs, .greaterThan),
        8: (.cellIs, .greaterThanOrEqual),
        9: (.cellIs, .lessThan),
        10: (.cellIs, .lessThanOrEqual),
        13: (.cellIs, .between),
        17: (.duplicateValues, nil),
        32: (.cellIs, .notBetween),
        34: (.uniqueValues, nil),
    ]

    /// The way back, for the writer.
    static let predicateTypes: [ConditionalFormattingRule.Kind: [ConditionalFormattingRule.Operator?: Int]] = {
        var out: [ConditionalFormattingRule.Kind: [ConditionalFormattingRule.Operator?: Int]] = [:]
        for (value, rule) in predicates { out[rule.kind, default: [:]][rule.op] = value }
        return out
    }()

    /// One rule as the model says it, or nil when the predicate is a kind we have not seen a document use.
    /// `style` resolves the rule's two style archives; `problems` collects what could not be read.
    static func rule(_ archive: ProtoMessage, priority: Int, style: (Int?, Int?) -> DifferentialStyle?,
                     problems: inout [String]) -> ConditionalFormattingRule? {
        guard let predicate = archive.message("predicate"), let type = predicate.int("predicate_type") else { return nil }
        guard let known = predicates[type] else {
            problems.append("condition kind \(type) has no name in the schema and no example in the corpus")
            return nil
        }
        var rule = ConditionalFormattingRule(kind: known.kind, priority: priority)
        rule.operator = known.op
        rule.style = style(archive.reference("cell_style"), archive.reference("text_style"))
        let values = [predicate.message("param_value1"), predicate.message("param_value2")].compactMap { $0 }
        for value in values {
            guard let text = argument(value) else { continue }
            rule.formulas.append(text)
        }
        // a text rule states what it looks for twice: as the rule's own `text`, and as the formula Excel evaluates
        if [.containsText, .notContainsText, .beginsWith, .endsWith].contains(known.kind) {
            rule.text = rule.formulas.first.map { $0.hasPrefix("\"") ? String($0.dropFirst().dropLast()) : $0 }
        }
        return rule
    }

    /// A predicate's parameter as formula text: a number as it reads, a string in quotes.
    private static func argument(_ value: ProtoMessage) -> String? {
        guard let data = value.message("arg_value") else { return nil }
        if let s = data.string("string_value") { return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        if data.has("decimal_low"), let low = data.uint("decimal_low"), let high = data.uint("decimal_high") {
            let bytes = withUnsafeBytes(of: low.littleEndian) { Array($0) } + withUnsafeBytes(of: high.littleEndian) { Array($0) }
            return "\(CellStorage.decodeDecimal128(bytes))"
        }
        if let d = data.double("double_value") {
            return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : "\(d)"
        }
        return nil
    }

    // MARK: - Writing

    /// One rule as Numbers keeps it, or nil for a kind Numbers has no word for (colour scales, data bars, icon
    /// sets, top-n, above-average, blanks, errors, dates, free formulas — the eleven it dropped on import).
    /// `tableUUID` is the table the rule lives on: the predicate's first parameter is the cell being tested,
    /// which Numbers writes as an offset of zero inside that table.
    static func archive(for rule: ConditionalFormattingRule, tableUUID: ProtoMessage?,
                        cellStyle: Int?, textStyle: Int?) -> ProtoMessage? {
        guard let type = predicateTypes[rule.kind]?[rule.operator] else { return nil }
        var predicate = ProtoMessage(typeName: "TST.FormulaPredicateArchive")
        predicate.set("predicate_type", int: type)
        predicate.set("qualifier1", int: 0)
        predicate.set("qualifier2", int: 0)

        var host = ProtoMessage(typeName: "TST.FormulaPredArgArchive")
        host.set("arg_type", int: 4)
        var relative = ProtoMessage(typeName: "TSCE.RelativeCellRefArchive")
        relative.set("relative_row_offset", int: 0)
        relative.set("relative_column_offset", int: 0)
        if let tableUUID { relative.set("table_uid", message: tableUUID) }
        host.set("relative_cell_ref", message: relative)
        predicate.set("param_value0", message: host)

        let values = arguments(for: rule)
        predicate.set("param_value1", message: values.0)
        predicate.set("param_value2", message: values.1)
        predicate.set("for_conditional_style", bool: true)

        var out = ProtoMessage(typeName: "TST.ConditionalStyleSetArchive.ConditionalStyleRule")
        out.set("predicate", message: predicate)
        if let cellStyle { out.set("cell_style", reference: cellStyle) }
        if let textStyle { out.set("text_style", reference: textStyle) }
        return out
    }

    /// The rule's own values. A comparison carries one (two for between); a text rule carries the string it looks
    /// for; duplicate and unique carry none, and Numbers still writes the empty slots.
    private static func arguments(for rule: ConditionalFormattingRule) -> (ProtoMessage, ProtoMessage) {
        // A text rule keeps what it looks for in `text`; `formulas` holds the formula Excel evaluates
        // (`NOT(ISERROR(SEARCH("pp",B1)))`), which is not what Numbers wants in the slot.
        let textKinds: Set<ConditionalFormattingRule.Kind> = [.containsText, .notContainsText, .beginsWith, .endsWith]
        var texts = textKinds.contains(rule.kind) ? [] : rule.formulas
        if texts.isEmpty, let text = rule.text { texts = ["\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""] }
        func argument(_ index: Int) -> ProtoMessage {
            var m = ProtoMessage(typeName: "TST.FormulaPredArgArchive")
            guard index < texts.count else { m.set("arg_type", int: 0); return m }
            let text = texts[index]
            var data = ProtoMessage(typeName: "TST.FormulaPredArgDataArchive")
            if text.hasPrefix("\"") {
                m.set("arg_type", int: 3)
                data.set("string_value", string: String(text.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\""))
            } else if let decimal = Decimal(string: text) {
                m.set("arg_type", int: 1)
                data.set("double_value", double: NSDecimalNumber(decimal: decimal).doubleValue)
                let bytes = CellStorage.encodeDecimal128(decimal)
                data.set("decimal_low", uint: littleEndian(bytes[0..<8]))
                data.set("decimal_high", uint: littleEndian(bytes[8..<16]))
            } else {
                m.set("arg_type", int: 3)
                data.set("string_value", string: text)
            }
            m.set("arg_value", message: data)
            return m
        }
        return (argument(0), argument(1))
    }

    private static func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        var v: UInt64 = 0
        for (i, b) in bytes.enumerated() { v |= UInt64(b) << (8 * UInt64(i)) }
        return v
    }
}
