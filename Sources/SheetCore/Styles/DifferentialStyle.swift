import Foundation

/// A *difference* to a cell's formatting rather than a whole formatting (`<dxf>`, openpyxl `DifferentialStyle`).
///
/// This is what a conditional-formatting rule paints with, what an Excel table's banded rows use, and what a colour
/// filter matches on. Every field is optional and every nil means "leave the cell as it already is" — a rule that
/// only turns the text red says exactly that and nothing about the fill, the border or the number format.
///
/// A style read from a file is written back **as the file had it**, byte for byte, unless it is edited: the entries
/// are index-referenced from several places at once, so they are seeded rather than rebuilt (the same treatment
/// `cellStyleXfs` gets). That also means the one thing this type cannot say — "explicitly *not* underlined", which
/// the format spells `<u val="none"/>` — survives a round trip even though `DifferentialFont` has no word for it.
public struct DifferentialStyle: Hashable, Sendable {
    public var font: DifferentialFont?
    public var fill: Fill?
    public var border: Border?
    /// The number-format code (`<numFmt formatCode>`), e.g. `"0.00%"`.
    public var numberFormat: String?
    public var alignment: Alignment?
    public var protection: Protection?

    public init(font: DifferentialFont? = nil, fill: Fill? = nil, border: Border? = nil,
                numberFormat: String? = nil, alignment: Alignment? = nil, protection: Protection? = nil) {
        self.font = font; self.fill = fill; self.border = border
        self.numberFormat = numberFormat; self.alignment = alignment; self.protection = protection
    }

    public var isEmpty: Bool { self == DifferentialStyle() }

    /// The everyday pair: a background and a text colour, either of which may be left alone.
    public static func highlight(fill: Color? = nil, text: Color? = nil) -> DifferentialStyle {
        DifferentialStyle(font: text.map { DifferentialFont(color: $0) }, fill: fill.map { Fill.solid($0) })
    }
}

/// The font attributes a `DifferentialStyle` overrides. Nil is "leave it alone", not "off": `bold == false` means
/// the rule takes bold *away*, while `bold == nil` means it says nothing about bold at all.
public struct DifferentialFont: Hashable, Sendable {
    public var name: String?
    public var size: Double?
    public var bold: Bool?
    public var italic: Bool?
    public var strikethrough: Bool?
    /// Nil says nothing about underlining. (The format can also say "no underline, definitely"; a style read from a
    /// file keeps that, but it cannot be built here — see `DifferentialStyle`.)
    public var underline: Font.Underline?
    public var color: Color?
    /// Superscript / subscript, verbatim ("superscript", "subscript", "baseline").
    public var vertAlign: String?

    public init(name: String? = nil, size: Double? = nil, bold: Bool? = nil, italic: Bool? = nil,
                strikethrough: Bool? = nil, underline: Font.Underline? = nil, color: Color? = nil,
                vertAlign: String? = nil) {
        self.name = name; self.size = size; self.bold = bold; self.italic = italic
        self.strikethrough = strikethrough; self.underline = underline; self.color = color; self.vertAlign = vertAlign
    }

    public var isEmpty: Bool { self == DifferentialFont() }
}
