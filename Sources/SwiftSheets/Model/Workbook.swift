import Foundation

public struct DocumentProperties: Hashable, Sendable {
    public var creator = "SwiftSheets"
    public var lastModifiedBy: String?
    public var title: String?
    public var subject: String?
    public var description: String?
    public var created: Date?
    public var modified: Date?
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
    public var definedNames: [String: String] = [:]
    public var activeIndex = 0

    public init() {
        worksheets = [Worksheet(title: "Sheet", workbook: self)]
    }

    /// Parses an .xlsx. With `dataOnly`, formula cells yield their cached values (openpyxl `data_only=True`).
    public convenience init(data: Data, dataOnly: Bool = false) throws {
        self.init(empty: ())
        try WorkbookReader.load(data, into: self, dataOnly: dataOnly)
    }

    public convenience init(contentsOf url: URL, dataOnly: Bool = false) throws {
        try self.init(data: try Data(contentsOf: url), dataOnly: dataOnly)
    }

    init(empty: Void) {}

    public var sheetNames: [String] { worksheets.map(\.title) }

    public var active: Worksheet {
        get { worksheets[min(activeIndex, worksheets.count - 1)] }
        set { if let i = worksheets.firstIndex(where: { $0 === newValue }) { activeIndex = i } }
    }

    public subscript(name: String) -> Worksheet? { worksheets.first { $0.title == name } }

    @discardableResult
    public func createSheet(_ title: String? = nil, at index: Int? = nil) -> Worksheet {
        var name = title ?? "Sheet"
        if title == nil { var n = 1; while sheetNames.contains(name) { name = "Sheet\(n)"; n += 1 } }
        let ws = Worksheet(title: name, workbook: self)
        if let index, index <= worksheets.count { worksheets.insert(ws, at: index) } else { worksheets.append(ws) }
        return ws
    }

    public func removeSheet(_ ws: Worksheet) {
        worksheets.removeAll { $0 === ws }
        activeIndex = min(activeIndex, max(0, worksheets.count - 1))
    }

    func addLoadedSheet(_ ws: Worksheet) { ws.workbook = self; worksheets.append(ws) }

    /// Serializes the workbook to .xlsx bytes.
    public func save() throws -> Data {
        try WorkbookWriter.write(self)
    }

    public func save(to url: URL) throws {
        try save().write(to: url)
    }
}
