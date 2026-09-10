import Foundation

/// The workbook's theme — the twelve scheme colours `Color.theme(_:tint:)` indexes and the two scheme fonts
/// (spec Appendix B.71). Read from `xl/theme/theme1.xml`; `Theme.office` is what Excel gives a new workbook and
/// what every colour resolves against when a workbook has no theme of its own.
public struct Theme: Hashable, Sendable {
    /// The twelve scheme colours as ARGB, in the order `<color theme="n"/>` indexes them: 0 = light 1 (background),
    /// 1 = dark 1 (text), 2 = light 2, 3 = dark 2, 4…9 = accent 1…6, 10 = hyperlink, 11 = followed hyperlink.
    /// Note the file's own order is dk1, lt1, dk2, lt2 — the index order swaps each pair, as Excel does.
    public var colors: [String]
    /// The headings font (`a:majorFont/a:latin`).
    public var majorFont: String?
    /// The body font (`a:minorFont/a:latin`) — what `Font.scheme == .minor` and the default font resolve to.
    public var minorFont: String?

    public init(colors: [String], majorFont: String? = nil, minorFont: String? = nil) {
        self.colors = colors.map { Color.normalizedARGB($0) }
        self.majorFont = majorFont; self.minorFont = minorFont
    }

    /// Excel's default "Office" theme (2013 and later).
    public static let office = Theme(
        colors: ["FFFFFF", "000000", "E7E6E6", "44546A", "4472C4", "ED7D31", "A5A5A5", "FFC000", "5B9BD5", "70AD47", "0563C1", "954F72"],
        majorFont: "Calibri Light", minorFont: "Calibri")

    /// The ARGB of theme colour `index` with `tint` applied (Excel's HLS luminance rule), or nil for an index the
    /// theme does not have.
    public func rgb(ofThemeColor index: Int, tint: Double = 0) -> String? {
        guard colors.indices.contains(index) else { return nil }
        return Color.applyingTint(tint, to: colors[index])
    }
}

extension Color {
    /// The 64 colours of the legacy indexed palette (ECMA-376 §18.8.27), plus 64 = system foreground and
    /// 65 = system background, as Excel resolves them when the file carries no `<indexedColors>` of its own.
    public static let defaultIndexedPalette: [String] = [
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "800000", "008000", "000080", "808000", "800080", "008080", "C0C0C0", "808080",
        "9999FF", "993366", "FFFFCC", "CCFFFF", "660066", "FF8080", "0066CC", "CCCCFF",
        "000080", "FF00FF", "FFFF00", "00FFFF", "800080", "800000", "008080", "0000FF",
        "00CCFF", "CCFFFF", "CCFFCC", "FFFF99", "99CCFF", "FF99CC", "CC99FF", "FFCC99",
        "3366FF", "33CCCC", "99CC00", "FFCC00", "FF9900", "FF6600", "666699", "969696",
        "003366", "339966", "003300", "333300", "993300", "993366", "333399", "333333",
        "000000", "FFFFFF",
    ].map { "FF" + $0 }

    /// "RRGGBB" or "AARRGGBB", any case → "AARRGGBB" upper-case.
    static func normalizedARGB(_ hex: String) -> String {
        let h = hex.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        return h.count == 6 ? "FF" + h : h
    }

    /// Excel's tint: the colour goes to HLS, the luminance is scaled toward black (tint < 0) or toward white
    /// (tint > 0), and the colour comes back (ECMA-376 §18.3.1.15).
    static func applyingTint(_ tint: Double, to argb: String) -> String {
        let hex = normalizedARGB(argb)
        guard tint != 0, hex.count == 8, let value = UInt32(hex, radix: 16) else { return hex }
        let alpha = (value >> 24) & 0xFF
        let r = Double((value >> 16) & 0xFF) / 255, g = Double((value >> 8) & 0xFF) / 255, b = Double(value & 0xFF) / 255
        let maxC = max(r, g, b), minC = min(r, g, b)
        var l = (maxC + minC) / 2
        var h = 0.0, s = 0.0
        if maxC != minC {
            let d = maxC - minC
            s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
            if maxC == r { h = (g - b) / d + (g < b ? 6 : 0) }
            else if maxC == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
        }
        l = tint < 0 ? l * (1 + tint) : l * (1 - tint) + tint
        func channel(_ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s
            let p = 2 * l - q
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let (nr, ng, nb) = s == 0 ? (l, l, l) : (channel(h + 1 / 3), channel(h), channel(h - 1 / 3))
        func byte(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        let out = (alpha << 24) | (byte(nr) << 16) | (byte(ng) << 8) | byte(nb)
        return String(format: "%08X", out)
    }
}

extension Workbook {
    /// The ARGB ("AARRGGBB") a colour resolves to in this workbook: an RGB colour as it is, a theme colour through
    /// `theme` (or `Theme.office` when the workbook has none) with its tint applied, an indexed colour through
    /// `indexedColors` when the file overrides the palette and the legacy palette otherwise. Nil for `.auto` and for
    /// an index neither has.
    public func rgb(of color: Color) -> String? {
        switch color {
        case .rgb(let hex): return Color.normalizedARGB(hex)
        case .theme(let i, let tint): return (theme ?? .office).rgb(ofThemeColor: i, tint: tint)
        case .indexed(let i):
            if indexedColors.indices.contains(i) { return Color.normalizedARGB(indexedColors[i]) }
            return Color.defaultIndexedPalette.indices.contains(i) ? Color.defaultIndexedPalette[i] : nil
        case .auto: return nil
        }
    }

    /// The colour as `.rgb` when it resolves, else unchanged.
    package func resolved(_ color: Color) -> Color { rgb(of: color).map { .rgb($0) } ?? color }

    /// A copy of the workbook in which every theme and indexed colour of the styles, differential styles,
    /// conditional formats, row and column styles and rich-text runs is the RGB it resolves to — what a writer for
    /// a format that has no theme (ODS, Numbers) works from. A font colour of `.theme(1)` with no tint — the text
    /// colour, which every default font carries — stays as it is, so that "default" keeps meaning default.
    package func resolvingColors() -> Workbook {
        var wb = self
        wb.namedStyles = namedStyles.map { var n = $0; n.style = resolved(n.style); return n }
        wb.differentialStyles = differentialStyles.map(resolved)
        for si in wb.sheets.indices {
            var sheet = wb.sheets[si]
            if let tab = sheet.tabColor, isUnresolved(tab) { sheet.tabColor = resolved(tab) }
            sheet.shapes = sheet.shapes.map { shape in
                var s = shape
                if let f = s.fill, isUnresolved(f) { s.fill = resolved(f) }
                if let o = s.outline, isUnresolved(o.color) { s.outline?.color = resolved(o.color) }
                if let f = s.font { s.font = resolved(f) }
                return s
            }
            for ti in sheet.tables.indices {
                var table = sheet.tables[ti]
                for (ref, cell) in table.cells {
                    var c = cell
                    var changed = false
                    if c.style.hasThemeOrIndexedColor { c.style = resolved(c.style); changed = true }
                    if case .richText(let runs)? = c.value, runs.contains(where: { $0.font?.color.map(isUnresolved) ?? false }) {
                        c.value = .richText(runs.map { var r = $0; if let f = r.font { r.font = resolved(f) }; return r })
                        changed = true
                    }
                    if changed { table.store(c, at: ref) }
                }
                for (row, dim) in table.rowDimensions where dim.style?.hasThemeOrIndexedColor == true {
                    table.rowDimensions[row]!.style = resolved(dim.style!)
                }
                for (col, dim) in table.columnDimensions where dim.style?.hasThemeOrIndexedColor == true {
                    table.columnDimensions[col]!.style = resolved(dim.style!)
                }
                sheet.tables[ti] = table
            }
            sheet.conditionalFormatting = sheet.conditionalFormatting.map { cf in
                var cf = cf
                cf.rules = cf.rules.map { rule in
                    var rule = rule
                    if let s = rule.style { rule.style = resolved(s) }
                    if var scale = rule.colorScale { scale.colors = scale.colors.map(resolved); rule.colorScale = scale }
                    if var bar = rule.dataBar { bar.color = resolved(bar.color); rule.dataBar = bar }
                    return rule
                }
                return cf
            }
            wb.sheets[si] = sheet
        }
        return wb
    }

    private func isUnresolved(_ color: Color) -> Bool {
        switch color {
        case .rgb, .auto: return false
        case .theme(1, let tint): return tint != 0
        case .theme, .indexed: return true
        }
    }
    private func resolvedKeepingTextDefault(_ color: Color?) -> Color? {
        guard let color, isUnresolved(color) else { return color }
        return resolved(color)
    }
    private func resolved(_ font: Font) -> Font { var f = font; f.color = resolvedKeepingTextDefault(f.color); return f }
    private func resolved(_ font: DifferentialFont) -> DifferentialFont { var f = font; f.color = resolvedKeepingTextDefault(f.color); return f }
    private func resolved(_ fill: Fill) -> Fill {
        switch fill {
        case .pattern(var p): p.foregroundColor = p.foregroundColor.map(resolved); p.backgroundColor = p.backgroundColor.map(resolved); return .pattern(p)
        case .gradient(var g): g.stops = g.stops.map { var s = $0; s.color = resolved(s.color); return s }; return .gradient(g)
        }
    }
    private func resolved(_ border: Border) -> Border {
        var b = border
        for path in [\Border.left, \Border.right, \Border.top, \Border.bottom, \Border.diagonal] {
            if let c = b[keyPath: path].color { b[keyPath: path].color = resolved(c) }
        }
        return b
    }
    private func resolved(_ style: CellStyle) -> CellStyle {
        var s = style
        s.font = resolved(s.font); s.fill = resolved(s.fill); s.border = resolved(s.border)
        return s
    }
    private func resolved(_ style: DifferentialStyle) -> DifferentialStyle {
        var s = style
        if let f = s.font { s.font = resolved(f) }
        if let f = s.fill { s.fill = resolved(f) }
        if let b = s.border { s.border = resolved(b) }
        return s
    }
}

extension CellStyle {
    /// Whether any colour of the style is a theme or indexed one (a text-coloured font, `.theme(1)`, excepted).
    package var hasThemeOrIndexedColor: Bool {
        func unresolved(_ c: Color?) -> Bool {
            switch c { case .theme(1, 0)?, .rgb?, .auto?, nil: return false; default: return true }
        }
        if unresolved(font.color) { return true }
        switch fill {
        case .pattern(let p): if unresolved(p.foregroundColor) || unresolved(p.backgroundColor) { return true }
        case .gradient(let g): if g.stops.contains(where: { unresolved($0.color) }) { return true }
        }
        return [border.left, border.right, border.top, border.bottom, border.diagonal].contains { unresolved($0.color) }
    }
}
