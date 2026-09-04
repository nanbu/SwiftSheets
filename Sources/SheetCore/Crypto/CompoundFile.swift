import Foundation

/// The OLE compound file ([MS-CFB]) — the container a password-protected Office file lives in. Read: the
/// directory tree and any stream in it. Write: the two-stream (plus DataSpaces) layout an encrypted package
/// needs, in version 3 (512-byte sectors), as Office itself writes it (spec Appendix B.39.9).
package struct CompoundFile {
    package struct Entry {
        package let name: String
        package let isStream: Bool
        package let size: Int
        let startSector: UInt32
        let left: UInt32, right: UInt32, child: UInt32
    }

    private let data: Data
    private let sectorSize: Int
    private let miniCutoff: Int
    private let fat: [UInt32]
    private let miniFat: [UInt32]
    private let entries: [Entry]
    private let miniStream: Data

    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let free: UInt32 = 0xFFFF_FFFF
    private static let noStream: UInt32 = 0xFFFF_FFFF

    package init(data: Data) throws {
        self.data = data
        guard data.count >= 512, [UInt8](data.prefix(8)) == UnopenableInput.compoundFileSignature else {
            throw SheetError.corruptedContainer(detail: "not a compound file")
        }
        let b = [UInt8](data.prefix(512))
        let shift = Int(Zip.u16(b, 0x1E))
        guard shift == 9 || shift == 12 else { throw SheetError.corruptedContainer(detail: "compound file sector size") }
        sectorSize = 1 << shift
        miniCutoff = Int(Zip.u32(b, 0x38))
        let fatCount = Int(Zip.u32(b, 0x2C))
        let firstDirectory = Zip.u32(b, 0x30)
        let firstMiniFat = Zip.u32(b, 0x3C), miniFatCount = Int(Zip.u32(b, 0x40))
        let firstDifat = Zip.u32(b, 0x44), difatCount = Int(Zip.u32(b, 0x48))
        // locals for the nested functions: a function in an initializer may not touch `self` before every
        // property is set, and the tables below are computed with these
        let file = data, ss = sectorSize
        let sectorCount = (file.count - 512 + ss - 1) / ss
        func sector(_ n: UInt32) throws -> Data {
            let start = 512 + Int(n) * ss
            guard n < 0xFFFF_FFF0, Int(n) < sectorCount, start < file.count else {
                throw SheetError.corruptedContainer(detail: "compound file sector \(n) is outside the file")
            }
            let end = Swift.min(start + ss, file.count)
            var s = file[(file.startIndex + start)..<(file.startIndex + end)]
            if s.count < ss { s.append(Data(count: ss - s.count)) }
            return Data(s)
        }
        // the FAT sectors are listed in the header (109) and in DIFAT sectors after that
        var fatSectors: [UInt32] = []
        for i in 0..<109 { let v = Zip.u32(b, 0x4C + i * 4); if v < 0xFFFF_FFF0 { fatSectors.append(v) } }
        var difat = firstDifat
        var hops = 0
        while difat < 0xFFFF_FFF0, hops < difatCount + 1 {
            let s = [UInt8](try sector(difat))
            for i in 0..<(ss / 4 - 1) { let v = Zip.u32(s, i * 4); if v < 0xFFFF_FFF0 { fatSectors.append(v) } }
            difat = Zip.u32(s, ss - 4)
            hops += 1
        }
        guard fatSectors.count >= fatCount else { throw SheetError.corruptedContainer(detail: "compound file FAT is incomplete") }
        var fatTable: [UInt32] = []
        for fs in fatSectors.prefix(fatCount) {
            let s = [UInt8](try sector(fs))
            for i in 0..<(ss / 4) { fatTable.append(Zip.u32(s, i * 4)) }
        }
        self.fat = fatTable
        func chain(from start: UInt32, in table: [UInt32]) throws -> [UInt32] {
            var out: [UInt32] = []
            var n = start
            var seen = Set<UInt32>()
            while n < 0xFFFF_FFF0 {
                guard seen.insert(n).inserted, Int(n) < table.count else { throw SheetError.corruptedContainer(detail: "compound file chain loops or runs off the table") }
                out.append(n)
                n = table[Int(n)]
            }
            return out
        }
        // directory
        var directory = Data()
        for n in try chain(from: firstDirectory, in: fatTable) { directory.append(try sector(n)) }
        var entryList: [Entry] = []
        let d = [UInt8](directory)
        var offset = 0
        while offset + 128 <= d.count {
            let nameLength = Int(Zip.u16(d, offset + 64))
            let type = d[offset + 66]
            var units: [UInt16] = []
            var k = 0
            while k + 1 < Swift.max(0, Swift.min(nameLength, 64) - 2) { units.append(UInt16(d[offset + k]) | UInt16(d[offset + k + 1]) << 8); k += 2 }
            let name = String(decoding: units, as: UTF16.self)
            let size = Int(Zip.u32(d, offset + 120))   // version 3: the low 32 bits are the size
            entryList.append(Entry(name: name, isStream: type == 2, size: type == 0 ? 0 : size, startSector: Zip.u32(d, offset + 116),
                                 left: Zip.u32(d, offset + 68), right: Zip.u32(d, offset + 72), child: Zip.u32(d, offset + 76)))
            offset += 128
        }
        self.entries = entryList
        // mini FAT and the mini stream (the root entry's stream)
        var miniFatTable: [UInt32] = []
        if miniFatCount > 0 {
            for n in try chain(from: firstMiniFat, in: fatTable) {
                let s = [UInt8](try sector(n))
                for i in 0..<(ss / 4) { miniFatTable.append(Zip.u32(s, i * 4)) }
            }
        }
        self.miniFat = miniFatTable
        var mini = Data()
        if let root = entryList.first, root.startSector < 0xFFFF_FFF0 {
            for n in try chain(from: root.startSector, in: fatTable) { mini.append(try sector(n)) }
            mini = mini.prefix(root.size)
        }
        miniStream = mini
    }

    /// The names of the streams, with their storage path ("\u{6}DataSpaces/Version").
    package var streamPaths: [String] {
        var out: [String] = []
        func walk(_ id: UInt32, prefix: String) {
            guard id != CompoundFile.noStream, Int(id) < entries.count else { return }
            let e = entries[Int(id)]
            walk(e.left, prefix: prefix)
            if e.isStream { out.append(prefix + e.name) } else { walk(e.child, prefix: prefix + e.name + "/") }
            walk(e.right, prefix: prefix)
        }
        if let root = entries.first { walk(root.child, prefix: "") }
        return out
    }

    /// A stream's bytes by path.
    package func stream(_ path: String) throws -> Data {
        let parts = path.split(separator: "/").map(String.init)
        guard let root = entries.first else { throw SheetError.corruptedContainer(detail: "compound file has no root") }
        var id = root.child
        for (i, part) in parts.enumerated() {
            var found: Entry?
            func find(_ n: UInt32) {
                guard found == nil, n != CompoundFile.noStream, Int(n) < entries.count else { return }
                let e = entries[Int(n)]
                if e.name == part { found = e; return }
                find(e.left); find(e.right)
            }
            find(id)
            guard let e = found else { throw SheetError.corruptedContainer(detail: "compound file has no stream \(path)") }
            if i == parts.count - 1 {
                guard e.isStream else { throw SheetError.corruptedContainer(detail: "\(path) is a storage, not a stream") }
                return try bytes(of: e)
            }
            id = e.child
        }
        throw SheetError.corruptedContainer(detail: "compound file has no stream \(path)")
    }

    private func bytes(of e: Entry) throws -> Data {
        var out = Data()
        var n = e.startSector
        var seen = Set<UInt32>()
        if e.size < miniCutoff {
            while n < 0xFFFF_FFF0, out.count < e.size {
                guard seen.insert(n).inserted, Int(n) < miniFat.count else { throw SheetError.corruptedContainer(detail: "compound file mini chain loops") }
                let start = Int(n) * 64
                guard start < miniStream.count else { throw SheetError.corruptedContainer(detail: "compound file mini sector outside the mini stream") }
                out.append(miniStream[(miniStream.startIndex + start)..<Swift.min(miniStream.endIndex, miniStream.startIndex + start + 64)])
                n = miniFat[Int(n)]
            }
        } else {
            while n < 0xFFFF_FFF0, out.count < e.size {
                guard seen.insert(n).inserted, Int(n) < fat.count else { throw SheetError.corruptedContainer(detail: "compound file chain loops") }
                let start = 512 + Int(n) * sectorSize
                guard start < data.count else { throw SheetError.corruptedContainer(detail: "compound file sector outside the file") }
                out.append(data[(data.startIndex + start)..<Swift.min(data.endIndex, data.startIndex + start + sectorSize)])
                n = fat[Int(n)]
            }
        }
        guard out.count >= e.size else { throw SheetError.corruptedContainer(detail: "compound file stream \(e.name) is truncated") }
        return out.prefix(e.size)
    }

    // MARK: - Writing

    /// A stream to write, at a path of storages ("\u{6}DataSpaces/Version").
    package struct StreamToWrite { package let path: String; package let data: Data; package init(_ path: String, _ data: Data) { self.path = path; self.data = data } }

    /// Writes a version 3 compound file holding `streams`. Streams under the mini cutoff go in the mini stream,
    /// the rest in regular sectors; the directory is a balanced-enough tree that any reader walks correctly
    /// (each storage's children are a chain of right siblings, as Office's own small files have them).
    package static func write(_ streams: [StreamToWrite]) -> Data {
        let sectorSize = 512
        let cutoff = 4096
        // the directory: root first; storages created on demand
        struct Dir { var name: String; var type: UInt8; var left: UInt32 = 0xFFFF_FFFF; var right: UInt32 = 0xFFFF_FFFF; var child: UInt32 = 0xFFFF_FFFF; var start: UInt32 = 0xFFFF_FFFE; var size: UInt32 = 0; var data: Data? }
        var dirs: [Dir] = [Dir(name: "Root Entry", type: 5)]
        var childrenOf: [Int: [Int]] = [:]
        func storage(_ path: [String]) -> Int {
            var parent = 0
            for name in path {
                if let existing = childrenOf[parent]?.first(where: { dirs[$0].name == name && dirs[$0].type == 1 }) { parent = existing; continue }
                dirs.append(Dir(name: name, type: 1))
                let id = dirs.count - 1
                childrenOf[parent, default: []].append(id)
                parent = id
            }
            return parent
        }
        for s in streams {
            let parts = s.path.split(separator: "/").map(String.init)
            let parent = storage(Array(parts.dropLast()))
            dirs.append(Dir(name: parts.last!, type: 2, data: s.data))
            childrenOf[parent, default: []].append(dirs.count - 1)
        }
        // children as a right-sibling chain, ordered by the compound file's name rule (length, then uppercase)
        for (parent, kids) in childrenOf {
            let ordered = kids.sorted { a, b in
                let na = dirs[a].name.uppercased(), nb = dirs[b].name.uppercased()
                return na.utf16.count != nb.utf16.count ? na.utf16.count < nb.utf16.count : na < nb
            }
            // a tiny red-black tree: middle element is the child, the rest hang left and right in order
            func tree(_ ids: ArraySlice<Int>) -> UInt32 {
                guard !ids.isEmpty else { return 0xFFFF_FFFF }
                let mid = ids.startIndex + ids.count / 2
                dirs[ids[mid]].left = tree(ids[ids.startIndex..<mid])
                dirs[ids[mid]].right = tree(ids[(mid + 1)...])
                return UInt32(ids[mid])
            }
            dirs[parent].child = tree(ordered[...])
        }
        // lay out the regular sectors: big streams, then the mini stream, then the mini FAT, then the directory
        var sectors: [Data] = []
        func addChain(_ payload: Data) -> UInt32 {
            guard !payload.isEmpty else { return 0xFFFF_FFFE }
            let first = UInt32(sectors.count)
            var offset = 0
            while offset < payload.count {
                var s = payload[(payload.startIndex + offset)..<Swift.min(payload.endIndex, payload.startIndex + offset + sectorSize)]
                if s.count < sectorSize { s.append(Data(count: sectorSize - s.count)) }
                sectors.append(Data(s)); offset += sectorSize
            }
            return first
        }
        var chains: [(start: Int, count: Int)] = []   // for the FAT
        for i in dirs.indices where dirs[i].type == 2 {
            let d = dirs[i].data!
            dirs[i].size = UInt32(d.count)
            if d.count >= cutoff {
                let start = sectors.count
                dirs[i].start = addChain(d)
                chains.append((start, sectors.count - start))
            }
        }
        // mini stream and mini FAT
        var mini = Data()
        var miniFat: [UInt32] = []
        for i in dirs.indices where dirs[i].type == 2 && dirs[i].data!.count < cutoff {
            let d = dirs[i].data!
            guard !d.isEmpty else { dirs[i].start = 0xFFFF_FFFE; continue }
            let first = UInt32(miniFat.count)
            var offset = 0
            while offset < d.count {
                var s = d[(d.startIndex + offset)..<Swift.min(d.endIndex, d.startIndex + offset + 64)]
                if s.count < 64 { s.append(Data(count: 64 - s.count)) }
                mini.append(s); offset += 64
                miniFat.append(offset < d.count ? UInt32(miniFat.count + 1) : 0xFFFF_FFFE)
            }
            dirs[i].start = first
        }
        dirs[0].size = UInt32(mini.count)
        let miniStart = sectors.count
        dirs[0].start = addChain(mini)
        chains.append((miniStart, sectors.count - miniStart))
        var miniFatData = Data()
        for v in miniFat { miniFatData.append(Zip.le32(v)) }
        while !miniFatData.isEmpty, miniFatData.count % sectorSize != 0 { miniFatData.append(Zip.le32(0xFFFF_FFFF)) }
        let miniFatStart = sectors.count
        let miniFatFirst = addChain(miniFatData)
        chains.append((miniFatStart, sectors.count - miniFatStart))
        // directory sectors (4 entries per 512-byte sector)
        var directory = Data()
        for d in dirs {
            var name = Data()
            for u in d.name.utf16 { name.append(Zip.le16(u)) }
            name.append(Zip.le16(0))
            let nameLength = UInt16(name.count)
            name.append(Data(count: 64 - name.count))
            directory.append(name)
            directory.append(Zip.le16(nameLength))
            directory.append(d.type); directory.append(1)                       // type; colour: black
            directory.append(Zip.le32(d.left)); directory.append(Zip.le32(d.right)); directory.append(Zip.le32(d.child))
            directory.append(Data(count: 16))                                   // CLSID
            directory.append(Zip.le32(0))                                       // state bits
            directory.append(Data(count: 16))                                   // times
            directory.append(Zip.le32(d.start))
            directory.append(Zip.le32(d.size)); directory.append(Zip.le32(0))
        }
        while directory.count % sectorSize != 0 {
            // an unused entry
            var pad = Data(count: 128)
            pad.replaceSubrange(68..<80, with: Zip.le32(0xFFFF_FFFF) + Zip.le32(0xFFFF_FFFF) + Zip.le32(0xFFFF_FFFF))
            directory.append(pad)
        }
        let directoryStart = sectors.count
        let directoryFirst = addChain(directory)
        chains.append((directoryStart, sectors.count - directoryStart))
        // the FAT itself: enough sectors to describe everything including itself
        var fatSectorCount = 0
        while (sectors.count + fatSectorCount) > fatSectorCount * (sectorSize / 4) { fatSectorCount += 1 }
        if fatSectorCount == 0 { fatSectorCount = 1 }
        var fat: [UInt32] = Array(repeating: 0xFFFF_FFFF, count: (sectors.count + fatSectorCount))
        for (start, count) in chains {
            for k in 0..<count { fat[start + k] = k == count - 1 ? 0xFFFF_FFFE : UInt32(start + k + 1) }
        }
        let fatStart = sectors.count
        for k in 0..<fatSectorCount { fat[fatStart + k] = 0xFFFF_FFFD }
        var fatData = Data()
        for v in fat { fatData.append(Zip.le32(v)) }
        while fatData.count < fatSectorCount * sectorSize { fatData.append(Zip.le32(0xFFFF_FFFF)) }
        _ = addChain(fatData)
        // header
        var header = Data()
        header.append(contentsOf: UnopenableInput.compoundFileSignature)
        header.append(Data(count: 16))                                          // CLSID
        header.append(Zip.le16(0x003E)); header.append(Zip.le16(3))             // minor, major
        header.append(Zip.le16(0xFFFE))                                         // byte order
        header.append(Zip.le16(9)); header.append(Zip.le16(6))                  // sector shift, mini sector shift
        header.append(Data(count: 6)); header.append(Zip.le32(0))               // reserved, directory sector count (v4 only)
        header.append(Zip.le32(UInt32(fatSectorCount)))
        header.append(Zip.le32(directoryFirst))
        header.append(Zip.le32(0))                                              // transaction signature
        header.append(Zip.le32(UInt32(cutoff)))
        header.append(Zip.le32(miniFatFirst)); header.append(Zip.le32(UInt32(miniFatData.isEmpty ? 0 : miniFatData.count / sectorSize)))
        header.append(Zip.le32(0xFFFF_FFFE)); header.append(Zip.le32(0))        // DIFAT: none beyond the header
        for k in 0..<109 { header.append(Zip.le32(k < fatSectorCount ? UInt32(fatStart + k) : 0xFFFF_FFFF)) }
        var out = header
        for s in sectors { out.append(s) }
        return out
    }
}
