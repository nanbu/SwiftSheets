import Foundation

/// docProps/core.xml (openpyxl `DocumentProperties`).
public struct DocumentProperties: Hashable, Sendable {
    public var creator = "SwiftSheets"
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

public struct SheetsError: Error, CustomStringConvertible, Sendable {
    public enum Kind: Sendable { case zip, xml, unsupported, invalid }
    public let kind: Kind
    public let message: String
    public init(_ kind: Kind, _ message: String) { self.kind = kind; self.message = message }
    public var description: String { "\(kind): \(message)" }
}

/// A workbook: ordered worksheets, document properties, the date epoch and defined names.
/// `Workbook()` starts with one empty sheet named "Sheet", like openpyxl. Load with `Workbook(data:)`, save with `save()`.
public final class Workbook {
    public private(set) var worksheets: [Worksheet] = []
    public var properties = DocumentProperties()
    public var epoch: DateEpoch = .windows1900
    /// Workbook-scoped defined names: name → formula text (sheet-scoped names live on `Worksheet.definedNames`).
    public var definedNames: [String: String] = [:]
    /// The legacy indexed palette (`<colors><indexedColors>`), when the file overrides it. ARGB strings.
    public var indexedColors: [String] = []
    public var activeIndex = 0
    /// VBA code name of the workbook (`<workbookPr codeName>`), preserved when present.
    public var codeName: String?
    /// True when the workbook was loaded with `dataOnly`, i.e. formula cells hold cached values (openpyxl `wb.data_only`).
    public internal(set) var dataOnly = false

    public init() {
        worksheets = [Worksheet(title: "Sheet", workbook: self)]
    }

    /// Parses an .xlsx. With `dataOnly`, formula cells yield their cached values (openpyxl `data_only=True`).
    public convenience init(data: Data, dataOnly: Bool = false) throws {
        self.init(empty: ())
        self.dataOnly = dataOnly
        try WorkbookReader.load(data, into: self, dataOnly: dataOnly)
    }

    public convenience init(contentsOf url: URL, dataOnly: Bool = false) throws {
        try self.init(data: try Data(contentsOf: url), dataOnly: dataOnly)
    }

    init(empty: Void) {}

    public var sheetNames: [String] { worksheets.map(\.title) }

    /// The active sheet. Setting a sheet that is hidden or belongs to another workbook is ignored (openpyxl raises).
    public var active: Worksheet {
        get { worksheets[Swift.min(activeIndex, worksheets.count - 1)] }
        set { if let i = worksheets.firstIndex(where: { $0 === newValue }), newValue.state == .visible { activeIndex = i } }
    }

    public subscript(name: String) -> Worksheet? { worksheets.first { $0.title == name } }
    public func contains(_ name: String) -> Bool { self[name] != nil }
    public func index(of ws: Worksheet) -> Int? { worksheets.firstIndex { $0 === ws } }

    /// Adds a sheet named `title` (default "Sheet"; duplicates get a numeric suffix as in openpyxl), at `index` or at the end.
    @discardableResult
    public func createSheet(_ title: String? = nil, at index: Int? = nil) -> Worksheet {
        let ws = Worksheet(title: Worksheet.uniqueTitle(title ?? "Sheet", among: sheetNames), workbook: self)
        if let index, index <= worksheets.count { worksheets.insert(ws, at: Swift.max(0, index)) } else { worksheets.append(ws) }
        return ws
    }

    public func removeSheet(_ ws: Worksheet) {
        worksheets.removeAll { $0 === ws }
        activeIndex = Swift.min(activeIndex, Swift.max(0, worksheets.count - 1))
    }

    /// `del wb["Sheet"]`.
    public func removeSheet(named name: String) { if let ws = self[name] { removeSheet(ws) } }

    /// Moves a sheet by `offset` positions (openpyxl `move_sheet`).
    public func moveSheet(_ ws: Worksheet, offset: Int) {
        guard let i = index(of: ws) else { return }
        worksheets.remove(at: i)
        worksheets.insert(ws, at: Swift.min(Swift.max(0, i + offset), worksheets.count))
    }
    public func moveSheet(named name: String, offset: Int) { if let ws = self[name] { moveSheet(ws, offset: offset) } }

    /// A copy of `ws` named "<title> Copy" (openpyxl `copy_worksheet`): values, styles, dimensions, merges and page setup.
    @discardableResult
    public func copyWorksheet(_ ws: Worksheet) -> Worksheet {
        let copy = createSheet(ws.title + " Copy")
        for (ref, c) in ws.cells {
            let n = copy.cell(row: ref.row, column: ref.column)
            n.style = c.style; n.value = c.value; n.hyperlink = c.hyperlink; n.comment = c.comment
        }
        copy.rowDimensions = ws.rowDimensions; copy.columnDimensions = ws.columnDimensions
        copy.mergedCells = ws.mergedCells; copy.sheetFormat = ws.sheetFormat; copy.properties = ws.properties
        copy.pageMargins = ws.pageMargins; copy.pageSetup = ws.pageSetup; copy.printOptions = ws.printOptions
        copy.currentRow = ws.currentRow
        return copy
    }

    func addLoadedSheet(_ ws: Worksheet) { ws.workbook = self; worksheets.append(ws) }

    /// Serializes the workbook to .xlsx bytes. `properties.modified` is written as set (2026-01-01 when unset), keeping
    /// output reproducible — openpyxl stamps the current time instead.
    public func save() throws -> Data {
        try WorkbookWriter.write(self)
    }

    public func save(to url: URL) throws {
        try save().write(to: url)
    }
}

extension Workbook: Sequence {
    public func makeIterator() -> IndexingIterator<[Worksheet]> { worksheets.makeIterator() }
}
