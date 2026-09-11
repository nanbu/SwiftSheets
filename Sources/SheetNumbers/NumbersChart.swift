import Foundation
import SheetCore

/// Charts on a Numbers sheet's canvas (spec Appendix B.88).
///
/// A Numbers chart is a `TSCH.ChartDrawableArchive` whose `TSCH.ChartArchive.unity` names the kind, a style
/// preset of the document (`TSCH.ChartStylePreset`, six in every document), the styles and "non-styles" (title,
/// legend, axis and series settings), a cached grid of the plotted numbers, and a **mediator**
/// (`TN.ChartMediatorArchive`) whose formulas point at the table cells the data comes from. The mediator is a
/// formula owner of the calculation engine (kind 2), registered like a table's.
///
/// Everything here copies what Numbers 15.3.1 wrote in `chart-and-control-15.numbers`: the reader follows the
/// mediator's formulas back to ranges, and the writer builds the same objects from the model's chart, pointing
/// every style at the template's first preset and filling the grid from the table's cells.
enum NumbersChart {
    /// The chart data function Numbers wraps every mediator formula in (index 175, one argument). Not a
    /// spreadsheet function: `functions.json` has no name for it.
    static let chartDataFunction = 175

    static let kinds: [(name: String, kind: Chart.Kind)] = [
        ("columnChartType2D", .column), ("barChartType2D", .bar), ("lineChartType2D", .line), ("pieChartType2D", .pie)
    ]

    // MARK: - Reading

    struct Read {
        var chart: Chart
    }

    /// The chart a drawable holds, with its series read back from the mediator's formulas. Nil when the chart's
    /// data is not linked to a table (pasted numbers only), which stays reported as "a chart".
    static func read(_ obj: ProtoMessage, doc: any NumbersObjectStore, tableName: @escaping (String) -> String?) -> Chart? {
        guard let unity = obj.message("TSCH.ChartArchive.unity"), let drawable = obj.message("super"),
              let frame = NumbersCanvas.frame(of: drawable) else { return nil }
        let typeNames = NumbersSchema.shared.enums["TSCH.ChartType"] ?? [:]
        let typeValue = unity.int("chart_type") ?? 0
        let typeName = typeNames.first { $0.value == typeValue }?.key ?? "undefinedChartType"
        let kind = kinds.first { $0.name == typeName }?.kind ?? Chart.Kind(rawValue: typeName)
        var chart = Chart(kind)
        chart.frame = CanvasRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        if let nonStyle = unity.reference("chart_non_style").flatMap({ doc.object($0) })?.message("TSCH.Generated.ChartNonStyleArchive.current") {
            if nonStyle.bool("tschchartinfodefaultshowtitle") != false, let title = nonStyle.string("tschchartinfodefaulttitle"), !title.isEmpty {
                chart.title = title
            }
            chart.legend = nonStyle.bool("tschchartinfodefaultshowlegend") ?? true
        }
        guard let mediator = unity.reference("mediator").flatMap({ doc.object($0) }), let formulas = mediator.message("formulas") else { return nil }
        var decoder = NumbersFormulaDecoder(tableName: tableName)
        func text(_ formula: ProtoMessage) -> String? {
            // the chart-data wrapper is the last node; the decoder has no name for it, so it is taken off first
            var f = formula
            if var array = f.message("AST_node_array") {
                var nodes = array.messages("AST_node")
                if let last = nodes.last, last.int("AST_function_node_index") == chartDataFunction { nodes.removeLast() }
                array.set("AST_node", messages: nodes)
                f.set("AST_node_array", message: array)
            }
            guard let t = decoder.text(for: f, row: 0, column: 0) else { return nil }
            // a range comes out of the decoder with the table on both ends ('T'!$B$2:'T'!$B$4); one is enough
            if let bang = t.firstIndex(of: "!"), let colon = t[bang...].firstIndex(of: ":") {
                let prefix = t[...bang]
                let rest = t[t.index(after: colon)...]
                if rest.hasPrefix(prefix) { return String(t[..<colon]) + ":" + String(rest.dropFirst(prefix.count)) }
            }
            return t
        }
        let data = formulas.messages("data_formulae").compactMap(text)
        guard !data.isEmpty else { return nil }
        let rowLabels = formulas.messages("row_label_formulae").compactMap(text)
        let colLabels = formulas.messages("col_label_formulae").compactMap(text)
        // one label list has an entry per series (the names), the other one per category
        let (names, categories): ([String], [String]) = colLabels.count == data.count ? (colLabels, rowLabels) : (rowLabels, colLabels)
        let categoryRange = range(spanning: categories)
        for (i, values) in data.enumerated() {
            let name = i < names.count ? names[i] : nil
            chart.series.append(Chart.Series(values: values, categories: categoryRange, name: nil, nameReference: name))
        }
        return chart
    }

    /// One range spanning a run of single-cell references on one table (`'T'!$A$2` … `'T'!$A$4` → `'T'!$A$2:$A$4`).
    static func range(spanning refs: [String]) -> String? {
        guard let first = refs.first, let last = refs.last else { return nil }
        guard refs.count > 1 else { return first }
        guard let a = CellRange(first), let b = CellRange(last), a.sheet == b.sheet else { return first }
        let prefix = first.contains("!") ? String(first[..<first.lastIndex(of: "!")!]) + "!" : ""
        let r = CellRange(minRow: Swift.min(a.minRow, b.minRow), minColumn: Swift.min(a.minColumn, b.minColumn),
                          maxRow: Swift.max(a.maxRow, b.maxRow), maxColumn: Swift.max(a.maxColumn, b.maxColumn))
        return prefix + cellsText(r)
    }

    // MARK: - Writing

    /// A reference's table and cells: `Sheet!$B$2:$B$4` names a sheet (its first table), `'Sheet::Table'!B2:B4`
    /// a table, and a bare `B2:B4` the chart's own sheet.
    static func resolve(_ ref: String, in workbook: Workbook, sheet: Sheet) -> (table: Table, range: CellRange, qualified: String)? {
        guard let range = CellRange(ref) else { return nil }
        let cells = CellRange(minRow: range.minRow, minColumn: range.minColumn, maxRow: range.maxRow, maxColumn: range.maxColumn)
        let (sheetName, tableName): (String, String?) = {
            guard let s = range.sheet else { return (sheet.name, nil) }
            if let sep = s.range(of: "::") { return (String(s[..<sep.lowerBound]), String(s[sep.upperBound...])) }
            return (s, nil)
        }()
        guard let target = workbook.sheets.first(where: { $0.name == sheetName }) else { return nil }
        let table: Table? = tableName.map { name in target.tables.first { $0.name == name } ?? nil } ?? target.tables.first
        guard let table else { return nil }
        let index = target.tables.firstIndex { $0.name == table.name && $0.anchor == table.anchor } ?? 0
        let qualified = "'" + sheetName + "::" + (table.name ?? "Table \(index + 1)") + "'!" + cellsText(cells)
        return (table, cells, qualified)
    }

    static func cellsText(_ r: CellRange) -> String {
        let a = "$" + CellRef.columnName(r.minColumn) + "$\(r.minRow)"
        let b = "$" + CellRef.columnName(r.maxColumn) + "$\(r.maxRow)"
        return a == b ? a : a + ":" + b
    }

    /// The cells of a range in reading order (down a column, then the next column).
    static func cells(_ r: CellRange) -> [CellRef] {
        var out: [CellRef] = []
        for c in r.minColumn...r.maxColumn { for row in r.minRow...r.maxRow { out.append(CellRef(row: row, column: c)) } }
        return out
    }

    /// The first chart style preset of the document, with the styles it names.
    struct Preset {
        var id: Int
        var chartStyle: Int?, legendStyle: Int?
        var valueAxisStyles: [Int], categoryAxisStyles: [Int], seriesStyles: [Int], paragraphStyles: [Int]
        var all: [Int] { [chartStyle, legendStyle].compactMap { $0 } + valueAxisStyles + categoryAxisStyles + seriesStyles + paragraphStyles }

        init?(in doc: NumbersDocument) {
            guard let id = doc.identifiers(ofType: "TSCH.ChartStylePreset").sorted().first, let p = doc.object(id) else { return nil }
            self.id = id
            chartStyle = p.reference("chart_style"); legendStyle = p.reference("legend_style")
            valueAxisStyles = p.references("value_axis_styles"); categoryAxisStyles = p.references("category_axis_styles")
            seriesStyles = p.references("series_styles"); paragraphStyles = p.references("paragraph_styles")
        }
    }

    static func nonStyle(_ type: String, current: String, _ fill: (inout ProtoMessage) -> Void = { _ in }) -> ProtoMessage {
        var m = ProtoMessage(typeName: type)
        m.set("super", message: ProtoMessage(typeName: "TSS.StyleArchive"))
        var c = ProtoMessage(typeName: current)
        fill(&c)
        m.set(current + ".current", message: c)
        return m
    }

    static func gridValue(_ v: Double) -> ProtoMessage {
        var g = ProtoMessage(typeName: "TSCH.GridValue"); g.set("numeric_value", double: v); return g
    }

    static func sparse(_ ids: [Int]) -> ProtoMessage {
        var a = ProtoMessage(typeName: "TSP.SparseReferenceArray")
        a.set("count", int: ids.count)
        a.set("entries", messages: ids.enumerated().map { i, id in
            var e = ProtoMessage(typeName: "TSP.SparseReferenceArray.Entry"); e.set("index", int: i); e.set("reference", reference: id); return e
        })
        return a
    }

    static func idMap(rows: Int, columns: Int) -> ProtoMessage {
        func entries(_ n: Int) -> [ProtoMessage] {
            (0..<n).map { i in
                var e = ProtoMessage(typeName: "TSCH.ChartGridArchive.ChartGridRowColumnIdMap.Entry")
                e.set("uniqueId", string: UUID().uuidString); e.set("index", int: i); return e
            }
        }
        var m = ProtoMessage(typeName: "TSCH.ChartGridArchive.ChartGridRowColumnIdMap")
        m.set("row_id_map", messages: entries(rows)); m.set("column_id_map", messages: entries(columns))
        return m
    }
}

extension NumbersWriter {
    /// Writes the sheet's charts as canvas objects (Appendix B.88): a drawable over the template's first style
    /// preset, the non-styles, the cached grid from the table's cells, and a mediator whose formulas name the
    /// cells and which is registered with the calculation engine as a formula owner.
    mutating func writeCharts(of sheet: Sheet, sheetID sid: Int, grid: NumbersCanvas.TableGrid) throws {
        guard !sheet.charts.isEmpty else { return }
        let file = doc.locations[sid]?.0 ?? "Index/Document.iwa"
        guard let preset = NumbersChart.Preset(in: doc) else {
            warnings.append(ConversionWarning(.dropped, subject: .objects, sheet: sheet.name, message: "\(sheet.charts.count) chart(s) dropped: the template has no chart style preset to draw with"))
            return
        }
        let names = tableUUIDs
        let tableUUID: (String) -> ProtoMessage? = { wanted in
            if let exact = names[wanted] { return exact }
            if let bySheet = names.keys.filter({ $0.hasPrefix(wanted + "::") }).sorted().first { return names[bySheet] }
            if let byTable = names.keys.filter({ $0.hasSuffix("::" + wanted) }).sorted().first { return names[byTable] }
            return nil
        }
        for chart in sheet.charts {
            guard chart.kind.isDrawable, let typeName = NumbersChart.kinds.first(where: { $0.kind == chart.kind })?.name else {
                warnings.append(ConversionWarning(.dropped, subject: .objects, sheet: sheet.name, message: "a \(chart.kind.rawValue) chart was not written: the writer draws column, bar, line and pie charts"))
                continue
            }
            let series = chart.series.compactMap { s -> (series: Chart.Series, values: (table: Table, range: CellRange, qualified: String))? in
                NumbersChart.resolve(s.values, in: workbook, sheet: sheet).map { (s, $0) }
            }
            guard !series.isEmpty else {
                warnings.append(ConversionWarning(.dropped, subject: .objects, sheet: sheet.name, message: "a \(chart.kind.rawValue) chart with no series on a table of this workbook was not written"))
                continue
            }
            if series.count < chart.series.count {
                warnings.append(ConversionWarning(.degraded, subject: .objects, sheet: sheet.name, message: "\(chart.series.count - series.count) series of a chart dropped: their ranges name no table of this workbook"))
            }
            let frame: NumbersCanvas.Frame
            if let anchor = chart.anchor { frame = grid.frame(.span(anchor), pixelWidth: 0, pixelHeight: 0) }
            else if let f = chart.frame { frame = NumbersCanvas.Frame(x: f.origin.x, y: f.origin.y, width: f.width, height: f.height) }
            else { frame = NumbersCanvas.Frame(x: 0, y: grid.top(ofRow: grid.table.nextAppendRow + 2), width: 400, height: 250) }

            // the categories: the first series' category range, one label formula per cell
            let categories = series.first?.series.categories.flatMap { NumbersChart.resolve($0, in: workbook, sheet: sheet) }
            let categoryCells = categories.map { NumbersChart.cells($0.range) } ?? []
            let categoryTexts = categoryCells.map { ref -> String in
                guard let v = categories?.table.cells[ref]?.value else { return "" }
                return v.stringValue ?? String(describing: v)
            }

            // formulas, each wrapped in the chart-data function
            // a chart has no table of its own: every reference names its table by UUID, as Numbers writes them
            var encoder = NumbersFormulaEncoder(hostTable: "\u{0}::\u{0}", tableUUID: tableUUID)
            func formula(_ text: String) -> ProtoMessage? {
                guard var f = encoder.archive(for: FormulaExpr.parse(text), row: 0, column: 0), var array = f.message("AST_node_array") else { return nil }
                var wrapper = ProtoMessage(typeName: "TSCE.ASTNodeArrayArchive.ASTNodeArchive")
                wrapper.set("AST_node_type", int: NumbersSchema.shared.enumValue("TSCE.ASTNodeArrayArchive.ASTNodeType", "FUNCTION_NODE") ?? 0)
                wrapper.set("AST_function_node_index", int: NumbersChart.chartDataFunction)
                wrapper.set("AST_function_node_numArgs", int: 1)
                array.append("AST_node", message: wrapper)
                f.set("AST_node_array", message: array)
                return f
            }
            var storage = ProtoMessage(typeName: "TN.ChartMediatorFormulaStorage")
            var dataFormulae: [ProtoMessage] = [], rowLabels: [ProtoMessage] = [], colLabels: [ProtoMessage] = []
            var gridRows: [ProtoMessage] = [], rowNames: [String] = []
            for (i, entry) in series.enumerated() {
                guard let f = formula(entry.values.qualified) else { continue }
                dataFormulae.append(f)
                let name = entry.series.name ?? entry.series.nameReference.flatMap { ref in
                    NumbersChart.resolve(ref, in: workbook, sheet: sheet).flatMap { r in r.table.cells[CellRef(row: r.range.minRow, column: r.range.minColumn)]?.value?.stringValue }
                } ?? "Series \(i + 1)"
                rowNames.append(name)
                if let ref = entry.series.nameReference, let r = NumbersChart.resolve(ref, in: workbook, sheet: sheet), let f = formula(r.qualified) {
                    colLabels.append(f)
                } else if let f = formula("\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"") {
                    colLabels.append(f)
                }
                var row = ProtoMessage(typeName: "TSCH.GridRow")
                row.set("value", messages: NumbersChart.cells(entry.values.range).map { ref in
                    NumbersChart.gridValue(entry.values.table.cells[ref]?.value?.doubleValue ?? 0)
                })
                gridRows.append(row)
            }
            if let categories {
                for ref in categoryCells {
                    let single = CellRange(minRow: ref.row, minColumn: ref.column, maxRow: ref.row, maxColumn: ref.column)
                    let qualified = String(categories.qualified[..<categories.qualified.lastIndex(of: "!")!]) + "!" + NumbersChart.cellsText(single)
                    if let f = formula(qualified) { rowLabels.append(f) }
                }
            }
            guard !dataFormulae.isEmpty else {
                warnings.append(ConversionWarning(.dropped, subject: .objects, sheet: sheet.name, message: "a \(chart.kind.rawValue) chart was not written: its series ranges could not be spelt for Numbers (\(encoder.problems.joined(separator: "; ")))"))
                continue
            }
            storage.set("data_formulae", messages: dataFormulae)
            storage.set("row_label_formulae", messages: rowLabels)
            storage.set("col_label_formulae", messages: colLabels)
            storage.set("direction", int: 2)
            storage.set("scheme", int: 0)

            // the mediator, a formula owner of the engine
            let entity = NumbersUUID.random()
            var mediator = ProtoMessage(typeName: "TN.ChartMediatorArchive")
            var base = ProtoMessage(typeName: "TSCH.ChartMediatorArchive")
            base.set("local_series_indexes", ints: Array(repeating: Int(UInt32.max), count: series.count))
            base.set("remote_series_indexes", ints: Array(1...series.count))
            mediator.set("super", message: base)
            mediator.set("entity_id", string: entity.string)
            mediator.set("formulas", message: storage)
            let mediatorID = try doc.add(mediator, file: file)

            // non-styles: the title and legend switches, the axes, one per series
            let chartNonStyle = try doc.add(NumbersChart.nonStyle("TSCH.ChartNonStyleArchive", current: "TSCH.Generated.ChartNonStyleArchive") { c in
                c.set("tschchartinfodefaultshowlegend", bool: chart.legend)
                c.set("tschchartinfodefaultshowtitle", bool: chart.title != nil)
                c.set("tschchartinfodefaultskiphiddendata", bool: true)
                if let title = chart.title { c.set("tschchartinfodefaulttitle", string: title) }
            }, file: file)
            let legendNonStyle = try doc.add(NumbersChart.nonStyle("TSCH.LegendNonStyleArchive", current: "TSCH.Generated.LegendNonStyleArchive"), file: file)
            func axisNonStyle() throws -> Int {
                var m = NumbersChart.nonStyle("TSCH.ChartAxisNonStyleArchive", current: "TSCH.Generated.ChartAxisNonStyleArchive")
                m.set("TSCH.axis_supports_custom_number_format", bool: true); m.set("TSCH.axis_supports_custom_date_format", bool: true)
                return try doc.add(m, file: file)
            }
            let valueAxisNonStyles = [try axisNonStyle(), try axisNonStyle()]
            let categoryAxisNonStyles = [try axisNonStyle()]
            var seriesNonStyles: [Int] = []
            for _ in series {
                var m = NumbersChart.nonStyle("TSCH.ChartSeriesNonStyleArchive", current: "TSCH.Generated.ChartSeriesNonStyleArchive") { c in
                    c.set("tschchartseriesdefaultnumberformattype", int: 1)
                }
                m.set("TSCH.series_supports_custom_number_format", bool: true); m.set("TSCH.series_supports_custom_date_format", bool: true)
                m.set("TSCH.series_supports_callout_lines", bool: true)
                seriesNonStyles.append(try doc.add(m, file: file))
            }

            // the drawable
            var unity = ProtoMessage(typeName: "TSCH.ChartArchive")
            unity.set("chart_type", int: NumbersSchema.shared.enumValue("TSCH.ChartType", typeName) ?? 1)
            unity.set("scatter_format", int: NumbersSchema.shared.enumValue("TSCH.ScatterFormat", "scatter_format_shared_x") ?? 2)
            unity.set("preset", reference: preset.id)
            unity.set("series_direction", int: NumbersSchema.shared.enumValue("TSCH.SeriesDirection", "series_direction_by_row") ?? 1)
            var gridArchive = ProtoMessage(typeName: "TSCH.ChartGridArchive")
            gridArchive.set("row_name", messages: [])
            for n in rowNames { gridArchive.fields.append(ProtoMessage.Field(number: NumbersSchema.shared.fieldNumber("TSCH.ChartGridArchive", "row_name")!, value: .bytes(Data(n.utf8)))) }
            for n in categoryTexts { gridArchive.fields.append(ProtoMessage.Field(number: NumbersSchema.shared.fieldNumber("TSCH.ChartGridArchive", "column_name")!, value: .bytes(Data(n.utf8)))) }
            gridArchive.set("grid_row", messages: gridRows)
            gridArchive.set("idMap", message: NumbersChart.idMap(rows: rowNames.count, columns: categoryTexts.count))
            unity.set("grid", message: gridArchive)
            unity.set("mediator", reference: mediatorID)
            if let s = preset.chartStyle { unity.set("chart_style", reference: s) }
            unity.set("chart_non_style", reference: chartNonStyle)
            if let s = preset.legendStyle { unity.set("legend_style", reference: s) }
            unity.set("legend_non_style", reference: legendNonStyle)
            unity.set("value_axis_styles", references: preset.valueAxisStyles)
            unity.set("value_axis_nonstyles", references: valueAxisNonStyles)
            unity.set("category_axis_styles", references: preset.categoryAxisStyles)
            unity.set("category_axis_nonstyles", references: categoryAxisNonStyles)
            unity.set("series_theme_styles", references: preset.seriesStyles)
            unity.set("series_private_styles", message: NumbersChart.sparse([]))
            unity.set("series_non_styles", message: NumbersChart.sparse(seriesNonStyles))
            unity.set("paragraph_styles", references: preset.paragraphStyles)
            unity.set("multidataset_index", int: 0)
            unity.set("needs_calc_engine_deferred_import_action", bool: false)
            unity.set("is_dirty", bool: true)
            for flag in ["TSCH.ChartPreserveAppearanceForPresetArchive.appearance_preserved_for_preset",
                         "TSCH.ChartSupportsProportionalBendedCalloutLinesArchive.supports_proportional_bended_callout_lines",
                         "TSCH.ChartSupportsRoundedCornersArchive.supports_rounded_corners",
                         "TSCH.ChartSupportsSeriesPropertySpacingArchive.supports_series_value_label_spacing",
                         "TSCH.ChartSupportsSeriesPropertySpacingArchive.supports_series_error_bar_spacing",
                         "TSCH.ChartSupportsStackedSummaryLabelsArchive.supports_stacked_summary_labels",
                         "TSCH.scene3d_settings_constant_depth"] {
                unity.set(flag, bool: true)
            }
            var drawableArchive = ProtoMessage(typeName: "TSCH.ChartDrawableArchive")
            var d = NumbersCanvas.drawable(frame, parent: sid)
            d.set("accessibility_description", string: chart.title ?? "Chart")
            drawableArchive.set("super", message: d)
            drawableArchive.set("TSCH.ChartArchive.unity", message: unity)
            let chartID = try doc.add(drawableArchive, file: file)
            doc.update(sid) { $0.append("drawable_infos", reference: chartID) }
            pendingCrossings.append((from: chartID, to: preset.all))

            // the engine knows the mediator as a formula owner of kind 2, owning the chart
            if let ownerID = try registerOwner(uid: entity.uuid, kind: 2, base: nil, formulaOwner: chartID) {
                pendingCrossings.append((from: ownerID, to: [chartID]))
            }
        }
    }
}
