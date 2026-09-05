import Foundation
import SheetCore
import SheetDecrypt

/// Writing a compound file — what an encrypted OOXML package is put into (spec Appendix B.39.9). The reader is
/// SheetDecrypt's; nothing that only opens protected files needs this.
extension CompoundFile {
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
