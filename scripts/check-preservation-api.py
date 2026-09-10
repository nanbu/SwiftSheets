#!/usr/bin/env python3
"""Check the preservation API from a genuinely separate SwiftPM package (Appendix B.46).

Build and run clients of both SheetCore and SwiftSheets, then require independent
negative probes to fail specifically because a name is hidden or read-only.
"""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
POSITIVE = '''
var workbook = Workbook()
let summary: PreservationSummary = workbook.preservationSummary
precondition(summary.sourceFormat == nil && summary.opaquePartCount == 0 && !summary.hasVBAProject)
let constructed = PreservationSummary(sourceFormat: .xlsx, opaquePartCount: 2, hasVBAProject: false)
precondition(constructed.opaquePartCount == 2)
let state: SheetContentState = workbook.sheets[0].contentState
switch state {
case .grid: break
case .unread, .nonGrid: fatalError("new sheets are grids")
}
var rule = ConditionalFormattingRule.contains("word", paint: DifferentialStyle())
rule.anchorTextFormula(at: "B2")
precondition(rule.formulas.first?.contains("B2") == true)
precondition(StructuredTable.sanitizedName("two words") == "two_words")
_ = CalculationSettings.asAssumedOutsideODF
print("public preservation API OK")
'''
NEGATIVE = [(name, f'_ = {name}.self', ["cannot find", "inaccessible"]) for name in
            ['PreservationStore', 'SheetPreservation', 'OpaquePart', 'XMLFragment',
             'Relationship', 'StyleTables', 'ForeignSheet',
             # plumbing that left the public surface in the 1.0 review (spec Appendix B.67)
             'ZipInspection', 'CRC32', 'TextEncodingSniffer', 'OOXMLEscape', 'Units', 'CellPixels', 'TextWidth',
             'LegacyPasswordHash', 'ModernPasswordHash']]
NEGATIVE += [('Table.cleanMergedRange', 'var t = Table(); t.cleanMergedRange(CellRange("A1:B2")!)', ['inaccessible']),
             ('WriteResult.suggest', '_ = WriteResult.suggest(from: [], target: .xlsx, options: WriteOptions())', ['inaccessible']),
             ('Workbook.noteUnmodelledODFFeatures', 'var w = Workbook(); w.noteUnmodelledODFFeatures([])', ['inaccessible'])]
NEGATIVE += [
    ('Workbook.preserved', '_ = Workbook().preserved', ['inaccessible']),
    ('Sheet.preserved', '_ = Sheet(name: "X").preserved', ['inaccessible']),
    ('Sheet.contentState', 'var s = Sheet(name: "X"); s.contentState = .unread', ['get-only']),
    ('Workbook.preservationSummary', 'var w = Workbook(); w.preservationSummary = w.preservationSummary', ['get-only']),
    ('PreservationSummary.sourceFormat', 'var s = Workbook().preservationSummary; s.sourceFormat = .csv', ["let", 'get-only']),
]


def run(directory, args, success=True, needles=()):
    result = subprocess.run(['swift', args[0], '--package-path', str(directory), *args[1:]], text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if success:
        if result.returncode:
            raise SystemExit(result.stdout)
    elif result.returncode == 0 or not any(n in result.stdout for n in needles):
        raise SystemExit('Negative probe did not fail for its expected reason:\n' + result.stdout)
    return result.stdout


with tempfile.TemporaryDirectory(prefix='swiftsheets-public-preservation-') as tmp:
    directory = Path(tmp)
    (directory / 'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "PreservationClient", platforms: [.macOS(.v14)],
    dependencies: [.package(path: PATH)],
    targets: [
        .executableTarget(name: "CoreClient", dependencies: [.product(name: "SheetCore", package: "SwiftSheets")]),
        .executableTarget(name: "FullClient", dependencies: [.product(name: "SwiftSheets", package: "SwiftSheets")])
    ])
'''.replace('PATH', json.dumps(str(ROOT))))
    for target, module in [('CoreClient', 'SheetCore'), ('FullClient', 'SwiftSheets')]:
        folder = directory / 'Sources' / target
        folder.mkdir(parents=True)
        (folder / 'main.swift').write_text(f'import {module}\n' + POSITIVE)
    run(directory, ['build'])
    for target in ['CoreClient', 'FullClient']:
        run(directory, ['run', '--skip-build', target])
        print(f'PASS: {target}', flush=True)
    source = directory / 'Sources' / 'FullClient' / 'main.swift'
    for name, code, needles in NEGATIVE:
        source.write_text('import SwiftSheets\n' + code + '\n')
        run(directory, ['build', '--product', 'FullClient'], success=False, needles=needles)
        print(f'PASS: external access rejected: {name}', flush=True)
    # Rebuild the successful client last so a poisoned build cannot make every negative probe pass.
    source.write_text('import SwiftSheets\n' + POSITIVE)
    run(directory, ['build', '--product', 'FullClient'])
    print('PASS: successful client rebuilt after negative probes', flush=True)
