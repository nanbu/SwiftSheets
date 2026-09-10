#!/usr/bin/env python3
"""Check the codec API from a genuinely separate SwiftPM package (Appendix B.50).

An application chooses formats with the `Codec` values its products publish, and the
format-specific codecs and streaming readers are the package's own business. Both halves
are compile-time claims, so they are proved from outside: four link configurations build
and run, then negative probes must fail for the stated reason.
"""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

# (target, products to link, the imports it may write, the codec values it may name)
CONFIGURATIONS = [
    ('XLSXClient', ['SheetCore', 'SheetXLSX'], ['SheetCore', 'SheetXLSX'], ['.xlsx', '.xlsm']),
    ('CSVClient', ['SheetCore', 'SheetCSV'], ['SheetCore', 'SheetCSV'], ['.csv']),
    ('TwoProductClient', ['SheetCore', 'SheetXLSX', 'SheetCSV'], ['SheetCore', 'SheetXLSX', 'SheetCSV'], ['.xlsx', '.csv']),
    ('FullClient', ['SwiftSheets'], ['SwiftSheets'], ['.xlsx', '.xlsm', '.ods', '.numbers', '.csv']),
]


def positive(values):
    """A client that builds a set out of the values its products publish, and uses it."""
    first = values[0]
    return f'''
let codecs = CodecSet([{', '.join(values)}])
precondition(codecs.formats == [{', '.join(values)}])
precondition(codecs.contains({first}) && codecs.formats.count == {len(values)})

// what comes back is the choice: it names its format, and that is all it offers
let chosen: Codec = try codecs.codec(for: {first})
precondition(chosen.format == {first})

// a set may hold nothing at all, and refuses by naming the product and the registration
let empty = CodecSet([])
precondition(empty.formats.isEmpty && !empty.contains({first}))
do {{
    _ = try empty.codec(for: {first})
    fatalError("an empty set has no codec to hand out")
}} catch {{
    let text = String(describing: error)
    precondition(text.contains("{first}") && text.contains("product"), text)
}}

// the round trip and the row-by-row reader work through the set alone
var workbook = Workbook()
workbook.sheets[0]["A1"] = "x"
let data = try codecs.write(workbook, as: {first}).data
let reopened = try codecs.read(data, format: {first}).workbook
precondition(reopened.sheets[0]["A1"] == .text("x"))
let reader = try codecs.streamingReader(data, format: {first})
let sheet = reader.sheetNames[0]
let names: [String?] = try reader.tableNames(inSheet: sheet)
let count = try reader.tableCount(inSheet: sheet)
precondition(names.count == count)
print("codec API OK")
'''


NEGATIVE = [
    # the implementations themselves are the package's business
    ('XLSXCodec', '_ = XLSXCodec.self', ['cannot find', 'inaccessible']),
    ('CSVCodec', '_ = CSVCodec.self', ['cannot find', 'inaccessible']),
    ('SpreadsheetCodec', 'let _: any SpreadsheetCodec.Type? = nil', ['cannot find', 'inaccessible']),
    ('XLSXStreamingReader', '_ = XLSXStreamingReader.self', ['cannot find', 'inaccessible']),
    ('CSVStreamingWriter', '_ = CSVStreamingWriter.self', ['cannot find', 'inaccessible']),
    # a Codec cannot be made, only named
    ('Codec.init', '_ = Codec(XLSXCodec.self)', ['cannot find', 'inaccessible', 'no exact matches']),
    ('Codec.implementation', '_ = try CodecSet([.xlsx]).codec(for: .xlsx).implementation',
     ['inaccessible', 'has no member']),
    # the codec that comes back is a choice, not a second door into the library
    ('Codec.read', '_ = try CodecSet([.xlsx]).codec(for: .xlsx).read(Data())', ['has no member']),
    # a format whose product is not linked cannot even be named
    ('Codec.numbers without SheetNumbers', '_ = CodecSet([.numbers])',
     ['has no member', 'cannot infer', 'type of expression is ambiguous']),
    # the old initializer is gone, not deprecated
    ('CodecSet([XLSXCodec.self])', '_ = CodecSet([XLSXCodec.self])', ['cannot find', 'inaccessible']),
]

# Named in Appendix B.50 as breaking with no public replacement.
NO_REPLACEMENT = [
    ('NumbersCodec.templateURL', '_ = NumbersCodec.templateURL', ['cannot find', 'inaccessible']),
    ('CSVStreamingReader.pieceSize', '_ = CSVStreamingReader.pieceSize', ['cannot find', 'inaccessible']),
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


def client(imports, body):
    return ''.join(f'import {module}\n' for module in ['Foundation'] + imports) + body


with tempfile.TemporaryDirectory(prefix='swiftsheets-public-codec-') as tmp:
    directory = Path(tmp)
    targets = ',\n        '.join(
        '.executableTarget(name: "%s", dependencies: [%s])'
        % (target, ', '.join(f'.product(name: "{p}", package: "SwiftSheets")' for p in products))
        for target, products, _, _ in CONFIGURATIONS)
    (directory / 'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "CodecClient", platforms: [.macOS(.v14)],
    dependencies: [.package(path: PATH)],
    targets: [
        TARGETS
    ])
'''.replace('PATH', json.dumps(str(ROOT))).replace('TARGETS', targets))
    for target, _, imports, values in CONFIGURATIONS:
        folder = directory / 'Sources' / target
        folder.mkdir(parents=True)
        (folder / 'main.swift').write_text(client(imports, positive(values)))
    run(directory, ['build'])
    for target, _, _, values in CONFIGURATIONS:
        run(directory, ['run', '--skip-build', target])
        print(f'PASS: {target}: {" ".join(values)} name their codecs, and the set does the work', flush=True)

    two = directory / 'Sources' / 'TwoProductClient' / 'main.swift'
    imports = CONFIGURATIONS[2][2]
    for name, code, needles in NEGATIVE:
        two.write_text(client(imports, code + '\n'))
        run(directory, ['build', '--product', 'TwoProductClient'], success=False, needles=needles)
        print(f'PASS: external access rejected: {name}', flush=True)

    full = directory / 'Sources' / 'FullClient' / 'main.swift'
    for name, code, needles in NO_REPLACEMENT:
        full.write_text(client(['SwiftSheets'], code + '\n'))
        run(directory, ['build', '--product', 'FullClient'], success=False, needles=needles)
        print(f'PASS: no public replacement, and none reachable: {name}', flush=True)

    # Rebuild the successful clients last so a poisoned build cannot make every negative probe pass.
    two.write_text(client(CONFIGURATIONS[2][2], positive(CONFIGURATIONS[2][3])))
    full.write_text(client(['SwiftSheets'], positive(CONFIGURATIONS[3][3])))
    run(directory, ['build'])
    print('PASS: the working clients build again after the negative probes', flush=True)
