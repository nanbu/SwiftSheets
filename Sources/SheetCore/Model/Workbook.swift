import Foundation

/// docProps/core.xml — author, title and friends.
public struct DocumentProperties: Hashable, Sendable {
    public var creator = SwiftSheetsInfo.name
    public var lastModifiedBy: String?
    public var title: String?
    public var subject: String?
    public var description: String?
    public var keywords: String?
    public var category: String?
    public var contentStatus: String?
    public var identifier: String?
    public var language: String?
    public var version: String?
    public var revision: String?
    public var created: Date?
    public var modified: Date?
    public var lastPrinted: Date?
    public init() {}
}

/// The ordered sheets of a workbook, addressable by index or by name. Names are validated and de-duplicated on the
/// way in (`\ * ? : / [ ]` and empty names are rejected — the previous name stays; duplicates get a numeric suffix),
/// and renaming a sheet rewrites the references to it in every formula of the workbook.
public struct Sheets: RandomAccessCollection, MutableCollection, RangeReplaceableCollection, Equatable, Sendable {
    private var storage: [Sheet] = []

    public init() {}
    public init(_ sheets: [Sheet]) { replaceSubrange(0..<0, with: sheets) }

    public var startIndex: Int { 0 }
    public var endIndex: Int { storage.count }
    public func index(after i: Int) -> Int { i + 1 }
    public func index(before i: Int) -> Int { i - 1 }

    public subscript(i: Int) -> Sheet {
        get { storage[i] }
        _modify {
            let old = storage[i].name
            yield &storage[i]
            if storage[i].name != old { didRename(at: i, from: old) }
        }
        set {
            let old = storage[i].name
            storage[i] = newValue
            if newValue.name != old { didRename(at: i, from: old) }
        }
    }

    /// `sheets["Sales"]`. Assigning replaces the sheet with that name, or appends it under that name when absent;
    /// assigning nil removes it.
    ///
    /// `wb.sheets["Sales"]?["A1"] = 1` edits in place: the sheet is moved out of the collection for the duration of
    /// the mutation and moved back, so a million cells are not copied on the way through.
    public subscript(name: String) -> Sheet? {
        get { storage.first { $0.name == name } }
        _modify {
            if let i = storage.firstIndex(where: { $0.name == name }) {
                let old = storage[i].name
                var sheet: Sheet? = storage.remove(at: i)   // moved out: the yielded value is the only reference
                defer {
                    if let s = sheet {
                        storage.insert(s, at: i)
                        if s.name != old { didRename(at: i, from: old) }
                    }
                }
                yield &sheet
            } else {
                var sheet: Sheet? = nil
                defer { if var s = sheet { s.name = name; append(s) } }
                yield &sheet
            }
        }
        set {
            if let i = storage.firstIndex(where: { $0.name == name }) {
                if let newValue { self[i] = newValue } else { storage.remove(at: i) }
            } else if var newValue { newValue.name = name; append(newValue) }
        }
    }

    public mutating func replaceSubrange<C: Collection>(_ range: Range<Int>, with newElements: C) where C.Element == Sheet {
        var kept = storage
        kept.removeSubrange(range)
        var incoming: [Sheet] = []
        for var s in newElements {
            if Sheet.validateName(s.name) != nil { s.name = "Sheet" }
            s.name = Sheet.uniqueName(s.name, among: kept.map(\.name) + incoming.map(\.name))
            incoming.append(s)
        }
        storage.replaceSubrange(range, with: incoming)
    }

    public var names: [String] { storage.map(\.name) }
    public func index(of name: String) -> Int? { storage.firstIndex { $0.name == name } }
    public func contains(_ name: String) -> Bool { index(of: name) != nil }

    /// Validates / de-duplicates the new name of sheet `i`, then rewrites formula references workbook-wide.
    private mutating func didRename(at i: Int, from old: String) {
        let proposed = storage[i].name
        guard Sheet.validateName(proposed) == nil else { storage[i].name = old; return }
        let others = storage.enumerated().filter { $0.offset != i }.map { $0.element.name }
        let final = Sheet.uniqueName(proposed, among: others)
        storage[i].name = final
        guard final != old else { return }
        for j in storage.indices {
            for t in storage[j].tables.indices {
                for (ref, cell) in storage[j].tables[t].cells {
                    guard case .formula(let f, let cached)? = cell.value, f.referencedSheets.contains(old) else { continue }
                    var c = cell; c.value = .formula(f.renamingSheet(old, to: final), cached: cached)
                    storage[j].tables[t].cells[ref] = c
                }
            }
        }
    }
}

/// A workbook: sheets, document metadata, defined names and the material kept for a lossless write-back.
/// A value type: edit freely, persist with `write(to:)` (SwiftSheets facade) or a codec's `write`.
public struct Workbook: Equatable, Sendable {
    public var sheets = Sheets()
    public var metadata = DocumentProperties()
    /// Which day serial 0 means in the file. Dates in the model are calendar dates; this only steers the XLSX codec.
    public var epoch: DateEpoch = .windows1900
    /// Workbook-scoped defined names: name → formula text (sheet-scoped names live on `Sheet.definedNames`).
    public var definedNames: [String: String] = [:]
    /// The legacy indexed palette (`<colors><indexedColors>`), when the file overrides it. ARGB strings.
    public var indexedColors: [String] = []
    /// VBA code name of the workbook (`<workbookPr codeName>`), preserved when present.
    public var codeName: String?
    /// Named cell styles, in the order the file lists them. Always starts with "Normal"; a cell points at one of
    /// these through `CellStyle.namedStyle`. Reading replaces the list with the file's; writing emits exactly it.
    public var namedStyles: [NamedStyle] = [.normal]
    /// True when loaded with `ReadOptions.dataOnly`: formula cells hold cached values.
    public var dataOnly = false
    /// Uninterpreted parts of the source file (charts, VBA, …), re-packed on a same-format write (spec §6).
    public var preserved = PreservationStore()
    /// The source file's format and generating application, when read from a file.
    public var sourceInfo: SourceInfo?
    /// What the file held that this model cannot say (spec §6). Filled in by every reader, so a plain
    /// `Workbook(contentsOf:)` never loses the report — `ReadResult` hands back the same list.
    public var readWarnings: [ConversionWarning] = []
    private var _activeIndex = 0

    /// A new workbook with one empty sheet named "Sheet1".
    public init() { sheets = Sheets([Sheet(name: "Sheet1")]) }
    public init(sheets: [Sheet]) { self.sheets = Sheets(sheets) }

    public var sheetNames: [String] { sheets.names }

    /// Adds (or replaces, by name) a named cell style. openpyxl's `wb.add_named_style`.
    public mutating func addNamedStyle(_ style: NamedStyle) {
        if let i = namedStyles.firstIndex(where: { $0.name == style.name }) { namedStyles[i] = style } else { namedStyles.append(style) }
    }

    /// The named style of that name, if the workbook has one.
    public func namedStyle(_ name: String) -> NamedStyle? { namedStyles.first { $0.name == name } }

    /// Index of the active sheet (clamped to the existing sheets). A hidden sheet cannot be made active — such an
    /// assignment is ignored (openpyxl raises).
    public var activeIndex: Int {
        get { sheets.isEmpty ? 0 : Swift.min(_activeIndex, sheets.count - 1) }
        set {
            if sheets.indices.contains(newValue), sheets[newValue].state != .visible { return }
            _activeIndex = Swift.max(0, newValue)
        }
    }

    /// The active sheet. Assigning replaces it in place, and mutating it through this property edits it where it
    /// lies rather than copying it out and back.
    public var activeSheet: Sheet {
        get { sheets[activeIndex] }
        _modify { yield &sheets[activeIndex] }
        set { sheets[activeIndex] = newValue }
    }

    // MARK: - Sheet management

    /// Adds an empty sheet (duplicate names get a numeric suffix) at `index` or at the end; returns its index.
    @discardableResult
    public mutating func addSheet(named name: String = "Sheet", at index: Int? = nil) -> Int {
        let at = index.map { Swift.max(0, Swift.min($0, sheets.count)) } ?? sheets.count
        sheets.insert(Sheet(name: name), at: at)
        return at
    }

    @discardableResult
    public mutating func removeSheet(named name: String) -> Bool {
        guard let i = sheets.index(of: name) else { return false }
        sheets.remove(at: i)
        return true
    }
    public mutating func removeSheet(at index: Int) { sheets.remove(at: index) }

    /// A copy of a sheet (values, styles, dimensions, merges, page setup — not its preserved drawings) placed at the
    /// end; returns the copy's index, nil when `name` does not exist.
    @discardableResult
    public mutating func duplicateSheet(named name: String, as newName: String? = nil) -> Int? {
        guard let src = sheets[name] else { return nil }
        var copy = src
        copy.name = newName ?? (name + " Copy")
        copy.preserved = SheetPreservation()
        copy.state = .visible
        sheets.append(copy)
        return sheets.count - 1
    }

    /// Moves a sheet to a new position.
    public mutating func moveSheet(named name: String, to index: Int) {
        guard let i = sheets.index(of: name) else { return }
        var all = Array(sheets)
        let s = all.remove(at: i)
        all.insert(s, at: Swift.max(0, Swift.min(index, all.count)))
        sheets = Sheets(all)
    }

    /// Renames a sheet; formulas referring to it follow. Returns the final name (de-duplicated) or nil when absent.
    @discardableResult
    public mutating func renameSheet(_ name: String, to newName: String) -> String? {
        guard let i = sheets.index(of: name) else { return nil }
        sheets[i].name = newName
        return sheets[i].name
    }

    // MARK: - Structure edits that other sheets must follow

    /// Inserts rows in a sheet and shifts references to it in every sheet's formulas.
    public mutating func insertRows(inSheet name: String, at index: Int, count: Int = 1) { shift(sheet: name, axis: .rows, at: index, delta: count) }
    public mutating func deleteRows(inSheet name: String, at index: Int, count: Int = 1) { shift(sheet: name, axis: .rows, at: index, delta: -count) }
    public mutating func insertColumns(inSheet name: String, at index: Int, count: Int = 1) { shift(sheet: name, axis: .columns, at: index, delta: count) }
    public mutating func deleteColumns(inSheet name: String, at index: Int, count: Int = 1) { shift(sheet: name, axis: .columns, at: index, delta: -count) }

    private mutating func shift(sheet name: String, axis: FormulaExpr.Axis, at index: Int, delta: Int) {
        guard let i = sheets.index(of: name) else { return }
        switch (axis, delta > 0) {
        case (.rows, true): sheets[i].insertRows(at: index, count: delta)
        case (.rows, false): sheets[i].deleteRows(at: index, count: -delta)
        case (.columns, true): sheets[i].insertColumns(at: index, count: delta)
        case (.columns, false): sheets[i].deleteColumns(at: index, count: -delta)
        }
        for j in sheets.indices where j != i {
            for t in sheets[j].tables.indices {
                for (ref, cell) in sheets[j].tables[t].cells {
                    guard case .formula(let f, let cached)? = cell.value, f.referencedSheets.contains(name) else { continue }
                    let shifted = f.shiftingReferences(axis: axis, at: index, delta: delta) { $0 == name }
                    if shifted != f { var c = cell; c.value = .formula(shifted, cached: cached); sheets[j].tables[t].cells[ref] = c }
                }
            }
        }
    }
}
