import Foundation

/// The two ways Numbers stores a 128-bit UUID (`TSP.UUID` upper/lower, `TSP.CFUUIDArchive` four words), as one hex key.
enum NumbersUUID {
    static func hex(_ m: ProtoMessage?) -> String? {
        guard let m, let t = m.typeName else { return nil }
        switch t {
        case "TSP.UUID":
            guard let lo = m.uint("lower"), let hi = m.uint("upper") else { return nil }
            return String(format: "%016llx%016llx", hi, lo)
        case "TSP.CFUUIDArchive":
            guard let w0 = m.uint("uuid_w0"), let w1 = m.uint("uuid_w1"), let w2 = m.uint("uuid_w2"), let w3 = m.uint("uuid_w3") else { return nil }
            return String(format: "%08llx%08llx%08llx%08llx", w3, w2, w1, w0)
        default: return nil
        }
    }

    /// The same UUID in the other spelling — a `TSP.UUID` as a `TSP.CFUUIDArchive`. Numbers uses one or the
    /// other depending on the archive, and a conditional-format rule needs both for the same table.
    static func cfuuid(_ uuid: ProtoMessage?) -> ProtoMessage? {
        guard let uuid, let lo = uuid.uint("lower"), let hi = uuid.uint("upper") else { return nil }
        var m = ProtoMessage(typeName: "TSP.CFUUIDArchive")
        m.set("uuid_w0", uint: lo & 0xFFFF_FFFF); m.set("uuid_w1", uint: lo >> 32)
        m.set("uuid_w2", uint: hi & 0xFFFF_FFFF); m.set("uuid_w3", uint: hi >> 32)
        return m
    }

    /// A table's `table_id` string as the `TSP.CFUUIDArchive` a cross-table reference names it by: the UUID's
    /// sixteen bytes read as four little-endian words. This is the identifier Numbers resolves such a reference
    /// through — neither the table's `haunted_owner` nor its dependency group's base owner (Appendix B.18).
    static func cfuuid(fromString string: String) -> ProtoMessage? {
        guard let u = UUID(uuidString: string) else { return nil }
        let t = u.uuid
        let bytes = [t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7, t.8, t.9, t.10, t.11, t.12, t.13, t.14, t.15]
        var m = ProtoMessage(typeName: "TSP.CFUUIDArchive")
        for (i, name) in ["uuid_w0", "uuid_w1", "uuid_w2", "uuid_w3"].enumerated() {
            var v: UInt64 = 0
            for k in 0..<4 { v |= UInt64(bytes[i * 4 + k]) << (8 * UInt64(k)) }
            m.set(name, uint: v)
        }
        return m
    }

    /// The UUID a **sub-owner** of `base` has: the base counted on by the sub-owner's kind. Every owner in a
    /// document Numbers wrote is its base plus its kind — the pivot's copy of the source is its summary's base
    /// plus 100, and that copy's two group-bys are the copy plus 205 and 206.
    ///
    /// This is not decoration. Numbers does not look a pivot's group-by up by the UUID in the archive: it
    /// *computes* one from the copy's UUID and the sub-owner index and asks the category owner for that
    /// (`-[TSTGroupBySet restoreFromPivotDataTable:…]`). A group-by carrying any other UUID is not found, its
    /// slot stays empty, and the pivot is rebuilt with no groups at all — which is what left the summary an
    /// empty shell for three sessions (Appendix B.19).
    static func subowner(of base: ProtoMessage?, kind: Int) -> ProtoMessage? {
        guard let base, let lo = base.uint("lower"), let hi = base.uint("upper") else { return nil }
        let (sum, carried) = lo.addingReportingOverflow(UInt64(kind))
        var m = ProtoMessage(typeName: "TSP.UUID")
        m.set("lower", uint: sum)
        m.set("upper", uint: carried ? hi &+ 1 : hi)
        return m
    }

    /// A table's `table_id` string as a `TSP.UUID` — the same sixteen bytes the cross-table form reads, in the
    /// spelling the owner UUIDs use. **This is the number a pivot's sub-owners are counted from**: Numbers derives
    /// them from the table's own identifier, not from whatever the calculation engine registered as its base owner.
    /// In a document Numbers wrote the two are the same value, so the difference is invisible there (Appendix B.19).
    static func uuid(fromString string: String) -> ProtoMessage? {
        guard let u = UUID(uuidString: string) else { return nil }
        let t = u.uuid
        let bytes = [t.0, t.1, t.2, t.3, t.4, t.5, t.6, t.7, t.8, t.9, t.10, t.11, t.12, t.13, t.14, t.15]
        var lo: UInt64 = 0, hi: UInt64 = 0
        for i in 0..<8 { lo |= UInt64(bytes[i]) << (8 * UInt64(i)) }
        for i in 0..<8 { hi |= UInt64(bytes[8 + i]) << (8 * UInt64(i)) }
        var m = ProtoMessage(typeName: "TSP.UUID")
        m.set("lower", uint: lo); m.set("upper", uint: hi)
        return m
    }

    /// A fresh random UUID as `TSP.UUID` / `TSP.CFUUIDArchive` messages and as the `table_id` string form.
    static func random() -> (uuid: ProtoMessage, cfuuid: ProtoMessage, string: String) {
        let u = UUID().uuid
        let bytes = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        var hi: UInt64 = 0, lo: UInt64 = 0
        for i in 0..<8 { hi = hi << 8 | UInt64(bytes[i]); lo = lo << 8 | UInt64(bytes[8 + i]) }
        var a = ProtoMessage(typeName: "TSP.UUID"); a.set("lower", uint: lo); a.set("upper", uint: hi)
        var b = ProtoMessage(typeName: "TSP.CFUUIDArchive")
        b.set("uuid_w0", uint: lo & 0xFFFF_FFFF); b.set("uuid_w1", uint: lo >> 32); b.set("uuid_w2", uint: hi & 0xFFFF_FFFF); b.set("uuid_w3", uint: hi >> 32)
        return (a, b, UUID(uuid: u).uuidString)
    }
}
