import Foundation
import SheetCore

/// A Protobuf message as an ordered list of wire-format fields. Nothing is dropped: fields the code does not know
/// travel through untouched and are re-emitted in their original order and encoding, which is what makes the
/// IWA round trip lossless (spec §10.2) without generated code. Typed access goes through the schema
/// (`NumbersSchema`) by message and field *name*, so field numbers are never spelled in Swift.
struct ProtoMessage: Hashable {
    enum Value: Hashable {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(Data)
    }
    struct Field: Hashable {
        var number: Int
        var value: Value
    }

    var typeName: String?
    var fields: [Field] = []

    init(typeName: String? = nil, fields: [Field] = []) { self.typeName = typeName; self.fields = fields }

    // MARK: - Wire codec

    init(decoding data: Data, typeName: String? = nil) throws {
        self.typeName = typeName
        let src = [UInt8](data)
        var i = 0
        func varint() throws -> UInt64 {
            var result: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard i < src.count else { throw SheetError.malformedPart(path: typeName ?? "protobuf", detail: "truncated varint") }
                let b = src[i]; i += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { throw SheetError.malformedPart(path: typeName ?? "protobuf", detail: "varint too long") }
            }
        }
        while i < src.count {
            let key = try varint()
            let number = Int(key >> 3), wire = key & 0x07
            switch wire {
            case 0: fields.append(Field(number: number, value: .varint(try varint())))
            case 1:
                guard i + 8 <= src.count else { throw SheetError.malformedPart(path: typeName ?? "protobuf", detail: "truncated fixed64") }
                var v: UInt64 = 0
                for k in 0..<8 { v |= UInt64(src[i + k]) << (8 * UInt64(k)) }
                i += 8
                fields.append(Field(number: number, value: .fixed64(v)))
            case 2:
                let declared = try varint()
                guard declared <= UInt64(src.count) else { throw SheetError.malformedPart(path: typeName ?? "protobuf", detail: "length-delimited field \(number) claims \(declared) bytes") }
                let len = Int(declared)
                guard i + len <= src.count else { throw SheetError.malformedPart(path: typeName ?? "protobuf", detail: "truncated length-delimited field \(number)") }
                fields.append(Field(number: number, value: .bytes(Data(src[i..<(i + len)]))))
                i += len
            case 5:
                guard i + 4 <= src.count else { throw SheetError.malformedPart(path: typeName ?? "protobuf", detail: "truncated fixed32") }
                var v: UInt32 = 0
                for k in 0..<4 { v |= UInt32(src[i + k]) << (8 * UInt32(k)) }
                i += 4
                fields.append(Field(number: number, value: .fixed32(v)))
            default: throw SheetError.malformedPart(path: typeName ?? "protobuf", detail: "unsupported wire type \(wire) for field \(number)")
            }
        }
    }

    func encoded() -> Data {
        var out = [UInt8]()
        func put(_ v: UInt64) { var n = v; repeat { var b = UInt8(n & 0x7F); n >>= 7; if n > 0 { b |= 0x80 }; out.append(b) } while n > 0 }
        for f in fields {
            switch f.value {
            case .varint(let v): put(UInt64(f.number) << 3); put(v)
            case .fixed64(let v): put(UInt64(f.number) << 3 | 1); for k in 0..<8 { out.append(UInt8((v >> (8 * UInt64(k))) & 0xFF)) }
            case .bytes(let d): put(UInt64(f.number) << 3 | 2); put(UInt64(d.count)); out.append(contentsOf: d)
            case .fixed32(let v): put(UInt64(f.number) << 3 | 5); for k in 0..<4 { out.append(UInt8((v >> (8 * UInt32(k))) & 0xFF)) }
            }
        }
        return Data(out)
    }

    var encodedSize: Int { encoded().count }

    // MARK: - Schema-driven typed access (by field name)

    /// The field number the schema gives this name, or nil when the schema does not know it — which is what a
    /// Numbers version newer than our schema looks like from here. Readers treat that as "the field is absent"
    /// (§10.3: read as far as you can and report), rather than taking the process down.
    private func number(_ name: String) -> Int? {
        guard let t = typeName, let n = NumbersSchema.shared.fieldNumber(t, name) else { return nil }
        return n
    }
    private func childType(_ name: String) -> String? { typeName.flatMap { NumbersSchema.shared.fieldTypeName($0, name) } }

    func has(_ name: String) -> Bool { guard let n = number(name) else { return false }; return fields.contains { $0.number == n } }

    func uint(_ name: String) -> UInt64? {
        guard let n = number(name) else { return nil }
        for f in fields where f.number == n { if case .varint(let v) = f.value { return v } }
        return nil
    }
    func int(_ name: String) -> Int? {
        guard let t = typeName, let info = NumbersSchema.shared.field(t, name) else { return nil }
        for f in fields where f.number == info.number {
            switch f.value {
            case .varint(let v): return info.type == "sint32" || info.type == "sint64" ? Int(ProtoMessage.zigzag(v)) : Int(Int64(bitPattern: v))
            case .fixed32(let v): return Int(v)
            case .fixed64(let v): return Int(Int64(bitPattern: v))
            default: continue
            }
        }
        return nil
    }
    func ints(_ name: String) -> [Int] {
        guard let t = typeName, let info = NumbersSchema.shared.field(t, name) else { return [] }
        var out: [Int] = []
        for f in fields where f.number == info.number {
            switch f.value {
            case .varint(let v): out.append(info.type == "sint32" || info.type == "sint64" ? Int(ProtoMessage.zigzag(v)) : Int(Int64(bitPattern: v)))
            case .fixed32(let v): out.append(Int(v))
            case .fixed64(let v): out.append(Int(Int64(bitPattern: v)))
            case .bytes(let d):   // packed
                var i = 0; let b = [UInt8](d)
                while i < b.count {
                    var v: UInt64 = 0, shift: UInt64 = 0
                    while i < b.count { let x = b[i]; i += 1; v |= UInt64(x & 0x7F) << shift; if x & 0x80 == 0 { break }; shift += 7 }
                    out.append(info.type == "sint32" || info.type == "sint64" ? Int(ProtoMessage.zigzag(v)) : Int(Int64(bitPattern: v)))
                }
            }
        }
        return out
    }
    func bool(_ name: String) -> Bool? { uint(name).map { $0 != 0 } }
    func double(_ name: String) -> Double? {
        guard let n = number(name) else { return nil }
        for f in fields where f.number == n {
            if case .fixed64(let v) = f.value { return Double(bitPattern: v) }
            if case .fixed32(let v) = f.value { return Double(Float(bitPattern: v)) }
        }
        return nil
    }
    func float(_ name: String) -> Float? {
        let n = number(name)
        for f in fields where f.number == n { if case .fixed32(let v) = f.value { return Float(bitPattern: v) } }
        return nil
    }
    func bytes(_ name: String) -> Data? {
        let n = number(name)
        for f in fields where f.number == n { if case .bytes(let d) = f.value { return d } }
        return nil
    }
    func string(_ name: String) -> String? { bytes(name).map { String(decoding: $0, as: UTF8.self) } }
    func strings(_ name: String) -> [String] {
        let n = number(name)
        return fields.compactMap { f in if f.number == n, case .bytes(let d) = f.value { String(decoding: d, as: UTF8.self) } else { nil } }
    }
    func message(_ name: String) -> ProtoMessage? {
        let n = number(name)
        for f in fields where f.number == n { if case .bytes(let d) = f.value { return try? ProtoMessage(decoding: d, typeName: childType(name)) } }
        return nil
    }
    func messages(_ name: String) -> [ProtoMessage] {
        let n = number(name), t = childType(name)
        return fields.compactMap { f in if f.number == n, case .bytes(let d) = f.value { try? ProtoMessage(decoding: d, typeName: t) } else { nil } }
    }
    /// The identifier of a `TSP.Reference` field.
    func reference(_ name: String) -> Int? { message(name)?.int("identifier") }
    func references(_ name: String) -> [Int] { messages(name).compactMap { $0.int("identifier") } }

    // MARK: - Mutation (replaces every existing occurrence of the field; appends when absent)

    private mutating func replace(_ name: String, with values: [Value]) {
        // writing is the other half: a field this build cannot name would go into the file as nothing, and a
        // silently incomplete Numbers document is worse than a loud one. The schema is bundled, so this is ours.
        guard let n = number(name) else { preconditionFailure("the bundled schema has no field \(typeName ?? "?").\(name)") }
        if let first = fields.firstIndex(where: { $0.number == n }) {
            fields.removeAll { $0.number == n }
            fields.insert(contentsOf: values.map { Field(number: n, value: $0) }, at: Swift.min(first, fields.count))
        } else {
            fields.append(contentsOf: values.map { Field(number: n, value: $0) })
        }
    }
    mutating func set(_ name: String, uint v: UInt64) { replace(name, with: [.varint(v)]) }
    mutating func set(_ name: String, int v: Int) {
        guard let t = typeName, let info = NumbersSchema.shared.field(t, name) else { preconditionFailure("unknown field \(name)") }
        switch info.type {
        case "sint32", "sint64": replace(name, with: [.varint(ProtoMessage.zigzagEncode(Int64(v)))])
        case "fixed32", "sfixed32": replace(name, with: [.fixed32(UInt32(truncatingIfNeeded: v))])
        case "fixed64", "sfixed64": replace(name, with: [.fixed64(UInt64(bitPattern: Int64(v)))])
        default: replace(name, with: [.varint(UInt64(bitPattern: Int64(v)))])
        }
    }
    /// A repeated scalar field, each value on its own — the unpacked spelling Numbers writes.
    mutating func set(_ name: String, ints v: [Int]) { replace(name, with: v.map { .varint(UInt64(bitPattern: Int64($0))) }) }
    mutating func set(_ name: String, bool v: Bool) { replace(name, with: [.varint(v ? 1 : 0)]) }
    mutating func set(_ name: String, double v: Double) { replace(name, with: [.fixed64(v.bitPattern)]) }
    mutating func set(_ name: String, float v: Float) { replace(name, with: [.fixed32(v.bitPattern)]) }
    mutating func set(_ name: String, bytes v: Data) { replace(name, with: [.bytes(v)]) }
    mutating func set(_ name: String, string v: String) { replace(name, with: [.bytes(Data(v.utf8))]) }
    mutating func set(_ name: String, message v: ProtoMessage) { replace(name, with: [.bytes(v.encoded())]) }
    mutating func set(_ name: String, messages v: [ProtoMessage]) { replace(name, with: v.map { .bytes($0.encoded()) }) }
    mutating func set(_ name: String, reference id: Int) { set(name, message: ProtoMessage.reference(id)) }
    mutating func set(_ name: String, references ids: [Int]) { set(name, messages: ids.map(ProtoMessage.reference)) }
    mutating func append(_ name: String, message v: ProtoMessage) {
        guard let n = number(name) else { preconditionFailure("the bundled schema has no field \(typeName ?? "?").\(name)") }
        fields.append(Field(number: n, value: .bytes(v.encoded())))
    }
    mutating func append(_ name: String, reference id: Int) { append(name, message: ProtoMessage.reference(id)) }
    mutating func remove(_ name: String) { guard let n = number(name) else { return }; fields.removeAll { $0.number == n } }
    /// Rewrites every nested message of a field in place.
    mutating func update(_ name: String, _ body: (inout ProtoMessage) -> Void) {
        let n = number(name), t = childType(name)
        for i in fields.indices where fields[i].number == n {
            if case .bytes(let d) = fields[i].value, var m = try? ProtoMessage(decoding: d, typeName: t) { body(&m); fields[i].value = .bytes(m.encoded()) }
        }
    }

    static func reference(_ id: Int) -> ProtoMessage { var m = ProtoMessage(typeName: "TSP.Reference"); m.set("identifier", int: id); return m }

    static func zigzag(_ v: UInt64) -> Int64 { Int64(v >> 1) ^ -Int64(v & 1) }
    static func zigzagEncode(_ v: Int64) -> UInt64 { UInt64(bitPattern: (v << 1) ^ (v >> 63)) }

    /// Every `TSP.Reference.identifier` reachable inside this message (schema-guided).
    func allReferences() -> [Int] {
        guard let t = typeName else { return [] }
        var out: [Int] = []
        for f in fields {
            guard case .bytes(let d) = f.value, let info = NumbersSchema.shared.field(t, number: f.number), info.type == "message", let child = info.typeName else { continue }
            if child == "TSP.Reference" { if let m = try? ProtoMessage(decoding: d, typeName: child), let id = m.int("identifier") { out.append(id) } }
            else if let m = try? ProtoMessage(decoding: d, typeName: child) { out.append(contentsOf: m.allReferences()) }
        }
        return out
    }

    /// A copy with every `TSP.Reference.identifier` remapped through `map` (ids absent from the map are kept).
    func remappingReferences(_ map: [Int: Int]) -> ProtoMessage {
        guard let t = typeName else { return self }
        var copy = self
        for i in copy.fields.indices {
            guard case .bytes(let d) = copy.fields[i].value, let info = NumbersSchema.shared.field(t, number: copy.fields[i].number), info.type == "message", let child = info.typeName else { continue }
            if child == "TSP.Reference" {
                if var m = try? ProtoMessage(decoding: d, typeName: child), let id = m.int("identifier"), let new = map[id] { m.set("identifier", int: new); copy.fields[i].value = .bytes(m.encoded()) }
            } else if let m = try? ProtoMessage(decoding: d, typeName: child) {
                let r = m.remappingReferences(map)
                if r != m { copy.fields[i].value = .bytes(r.encoded()) }
            }
        }
        return copy
    }
}

/// The machine-extracted schema (Sources/SheetNumbers/Resources/schema.json, registry.json, functions.json,
/// constants.json, fonts.json — see NOTICE).
final class NumbersSchema: Sendable {
    struct FieldInfo: Sendable { let name: String; let number: Int; let type: String; let typeName: String?; let repeated: Bool }
    static let shared = NumbersSchema()

    private let fieldsByName: [String: [String: FieldInfo]]
    private let fieldsByNumber: [String: [Int: FieldInfo]]
    let enums: [String: [String: Int]]
    /// IWA message type id → fully qualified message name.
    let registry: [Int: String]
    let registryByName: [String: Int]
    /// Numbers function id → name, and the way back for the formula writer.
    let functions: [Int: String]
    let functionIndexes: [String: Int]
    /// The integer constants Apple left unnamed in the Protobuf (number-format kinds, alignment, duration styles),
    /// recovered by numbers-parser: group name → case name → value.
    let constants: [String: [String: Int]]
    /// PostScript font name → family name, and the first PostScript name of each family for the way back.
    let fontFamilies: [String: String]
    let fontPostScriptNames: [String: String]
    let sourceVersion: String

    private init() {
        func load(_ name: String) -> [String: Any] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "json"), let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { preconditionFailure("SheetNumbers resource \(name).json missing") }
            return obj
        }
        let schema = load("schema")
        var byName: [String: [String: FieldInfo]] = [:], byNumber: [String: [Int: FieldInfo]] = [:]
        for (msg, body) in schema["messages"] as? [String: [String: Any]] ?? [:] {
            var n: [String: FieldInfo] = [:], m: [Int: FieldInfo] = [:]
            for f in body["fields"] as? [[String: Any]] ?? [] {
                let info = FieldInfo(name: f["name"] as! String, number: f["number"] as! Int, type: f["type"] as! String, typeName: f["typeName"] as? String, repeated: (f["label"] as? String) == "repeated")
                n[info.name] = info; m[info.number] = info
            }
            byName[msg] = n; byNumber[msg] = m
        }
        fieldsByName = byName; fieldsByNumber = byNumber
        enums = (schema["enums"] as? [String: [String: Int]]) ?? [:]
        sourceVersion = ((schema["_meta"] as? [String: Any])?["version"] as? String) ?? "?"
        let reg = load("registry")["types"] as? [String: String] ?? [:]
        var r: [Int: String] = [:]
        for (k, v) in reg { if let i = Int(k) { r[i] = v } }
        registry = r
        registryByName = Dictionary(r.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        constants = (load("constants")["constants"] as? [String: [String: Int]]) ?? [:]
        let families = (load("fonts")["families"] as? [String: String]) ?? [:]
        fontFamilies = families
        // the family's plain face is the shortest of its names, which is the one Numbers uses for a plain run
        var byFamily: [String: String] = [:]
        for (postScript, family) in families {
            if let existing = byFamily[family], (existing.count, existing) <= (postScript.count, postScript) { continue }
            byFamily[family] = postScript
        }
        fontPostScriptNames = byFamily
        let fn = load("functions")["functions"] as? [String: String] ?? [:]
        var f: [Int: String] = [:]
        for (k, v) in fn { if let i = Int(k) { f[i] = v } }
        functions = f
        functionIndexes = Dictionary(f.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func field(_ message: String, _ name: String) -> FieldInfo? { fieldsByName[message]?[name] }
    func field(_ message: String, number: Int) -> FieldInfo? { fieldsByNumber[message]?[number] }
    func fieldNumber(_ message: String, _ name: String) -> Int? { field(message, name)?.number }
    func fieldTypeName(_ message: String, _ name: String) -> String? { field(message, name)?.typeName }
    func enumValue(_ enumName: String, _ caseName: String) -> Int? { enums[enumName]?[caseName] }
    func enumCase(_ enumName: String, _ value: Int) -> String? { enums[enumName]?.first { $0.value == value }?.key }
    func knows(_ message: String) -> Bool { fieldsByName[message] != nil }
    /// A named constant of `constants.json`, e.g. `constant("FormatType", "PERCENT")`.
    func constant(_ group: String, _ name: String) -> Int? { constants[group]?[name] }
    func constantName(_ group: String, _ value: Int) -> String? { constants[group]?.first { $0.value == value }?.key }
    /// "HelveticaNeue-Bold" → "Helvetica Neue"; an unknown name is its own family.
    func fontFamily(_ postScript: String) -> String { fontFamilies[postScript] ?? postScript }
    /// "Helvetica Neue" → "HelveticaNeue"; an unknown family is written as it stands.
    func fontPostScriptName(_ family: String) -> String { fontPostScriptNames[family] ?? family }
}
