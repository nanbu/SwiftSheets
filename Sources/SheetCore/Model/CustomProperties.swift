import Foundation

/// One entry of `docProps/custom.xml` — the free-form fields an organisation puts on a workbook beside the built-in
/// author and title: a document number, a review date, a "confidential" flag.
///
/// The built-in fields live on `Workbook.metadata`; these are the ones nobody but the author has agreed on, so the
/// name is a plain string and the value carries its own type. Excel shows them under File ▸ Info ▸ Properties ▸
/// Custom, and openpyxl calls the collection `wb.custom_doc_props`.
public struct CustomDocumentProperty: Hashable, Sendable {
    /// The value and, with it, the type the file declares for it (the `vt:` element inside `<property>`).
    public enum Value: Hashable, Sendable {
        case text(String)
        case integer(Int)
        case number(Double)
        case bool(Bool)
        /// A moment, not a calendar date: the format stores these as UTC file times, so unlike a cell's `.date`
        /// this one really is a `Date`.
        case date(Date)
        /// Not stored at all — the property shows whatever the named cell or defined name holds (`linkTarget`).
        case link(String)
    }

    /// The name shown in the properties dialog. Names are unique within a workbook.
    public var name: String
    public var value: Value

    public init(name: String, value: Value) { self.name = name; self.value = value }
    public init(name: String, _ text: String) { self.init(name: name, value: .text(text)) }
    public init(name: String, _ value: Int) { self.init(name: name, value: .integer(value)) }
    public init(name: String, _ value: Double) { self.init(name: name, value: .number(value)) }
    public init(name: String, _ value: Bool) { self.init(name: name, value: .bool(value)) }
    public init(name: String, _ value: Date) { self.init(name: name, value: .date(value)) }

    /// The property whose value follows `definedName` (a defined name or a single-cell range) instead of being
    /// stored in the file.
    public static func linked(name: String, to definedName: String) -> CustomDocumentProperty {
        CustomDocumentProperty(name: name, value: .link(definedName))
    }

    public var text: String? { if case .text(let v) = value { return v }; return nil }
    public var integer: Int? { if case .integer(let v) = value { return v }; return nil }
    public var number: Double? { if case .number(let v) = value { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = value { return v }; return nil }
    public var date: Date? { if case .date(let v) = value { return v }; return nil }
    public var linkTarget: String? { if case .link(let v) = value { return v }; return nil }
}

/// The custom properties of a workbook, in the file's order and addressable by name.
public struct CustomDocumentProperties: RandomAccessCollection, Equatable, Sendable, ExpressibleByArrayLiteral {
    private var storage: [CustomDocumentProperty] = []

    public init() {}
    public init(_ properties: [CustomDocumentProperty]) { for p in properties { self[p.name] = p.value } }
    public init(arrayLiteral elements: CustomDocumentProperty...) { self.init(elements) }

    public var startIndex: Int { 0 }
    public var endIndex: Int { storage.count }
    public subscript(i: Int) -> CustomDocumentProperty { storage[i] }

    /// The value of the property of that name. Assigning replaces it in place, or appends it; nil removes it.
    public subscript(name: String) -> CustomDocumentProperty.Value? {
        get { storage.first { $0.name == name }?.value }
        set {
            let i = storage.firstIndex { $0.name == name }
            switch (newValue, i) {
            case (let v?, let i?): storage[i].value = v
            case (let v?, nil): storage.append(CustomDocumentProperty(name: name, value: v))
            case (nil, let i?): storage.remove(at: i)
            case (nil, nil): break
            }
        }
    }

    public var names: [String] { storage.map(\.name) }
    public func contains(_ name: String) -> Bool { storage.contains { $0.name == name } }
    @discardableResult
    public mutating func remove(_ name: String) -> Bool {
        guard let i = storage.firstIndex(where: { $0.name == name }) else { return false }
        storage.remove(at: i)
        return true
    }
}
