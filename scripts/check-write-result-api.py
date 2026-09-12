#!/usr/bin/env python3
"""Compile external clients against all five non-discardable save APIs (spec B.47).

No @testable or package identity: diagnostics must survive the exported modules.
Each ignored call must warn, fail with warnings-as-errors, and accept explicit use.
The removed data conveniences must fail while their write replacements compile (B.48).
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CALLS = [
    ('CodecSet.write', 'import SheetCore', 'codecs.write(workbook, to: url, as: .csv)'),
    ('CodecSet.convert', 'import SheetCore', 'codecs.convert(url, to: url, as: .csv)'),
    ('Workbook.write', 'import SwiftSheets', 'workbook.write(to: url, as: .csv)'),
    ('Workbook.convert', 'import SwiftSheets', 'Workbook.convert(url, to: url, as: .csv)'),
    ('Workbook.write.password', 'import SheetEncrypt', 'workbook.write(to: url, as: .xlsx, password: "test")'),
]


def main():
    subprocess.run(['swift', 'build'], cwd=ROOT, check=True)
    binary = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
    with tempfile.TemporaryDirectory(prefix='swiftsheets-write-result-') as tmp:
        source = Path(tmp) / 'Client.swift'
        # SwiftPM before 6.4 puts the .swiftmodule files in Modules/ under the bin path; the build system of 6.4 puts
        # them in the bin path itself (.build/out/Products/Debug).
        modules = binary / 'Modules' if (binary / 'Modules').is_dir() else binary
        command = ['swiftc', '-typecheck', '-I', str(modules),
                   '-I', str(ROOT / 'Sources/CZlib'), str(source)]
        for name, module, call in CALLS:
            prefix = f'import Foundation\n{module}\nfunc probe(_ workbook: Workbook, _ codecs: CodecSet, _ url: URL) throws {{\n'
            source.write_text(prefix + f'    try {call}\n}}\n')
            for strict in [False, True]:
                result = subprocess.run(command + (['-warnings-as-errors'] if strict else []),
                                        text=True, capture_output=True)
                output = result.stdout + result.stderr
                diagnostic = 'error:' if strict else 'warning:'
                if ((result.returncode != 0) != strict or diagnostic not in output
                        or 'result of call to' not in output or 'is unused' not in output):
                    raise SystemExit(f'{name}: expected unused-result {diagnostic}\n{output}')
            # Same overload, same arguments; merely acknowledge or use the return value.
            source.write_text(prefix + f'    _ = try {call}\n    let result = try {call}\n'
                              + '    print(result.warnings, result.data.count, result.suggestion as Any)\n}\n')
            result = subprocess.run(command + ['-warnings-as-errors'], text=True, capture_output=True)
            if result.returncode:
                raise SystemExit(f'{name}: explicit use failed\n{result.stdout}{result.stderr}')
            print(f'PASS: {name}: warns, errors in strict mode, accepts explicit use', flush=True)

        for module, receiver in [('SheetCore', 'codecs'), ('SwiftSheets', 'Workbook')]:
            prefix = f'import Foundation\nimport {module}\nfunc probe(_ codecs: CodecSet, _ source: URL, _ destination: URL) throws {{\n'
            call = f'{receiver}.convert(source, to: destination, as: .csv, readOptions: ReadOptions(), writeOptions: WriteOptions())'
            source.write_text(prefix + f'    let result: WriteResult = try {call}\n    print(result.data, result.warnings, result.suggestion as Any)\n}}\n')
            result = subprocess.run(command + ['-warnings-as-errors'], text=True, capture_output=True)
            if result.returncode:
                raise SystemExit(f'{receiver}: explicit conversion options failed\n{result.stdout}{result.stderr}')
            for arguments, diagnostic in [
                ('source, to: SheetFormat.csv, output: destination', "extra argument 'output'"),
                ('source, to: destination', "missing argument for parameter 'as'"),
            ]:
                source.write_text(prefix + f'    _ = try {receiver}.convert({arguments})\n}}\n')
                result = subprocess.run(command, text=True, capture_output=True)
                output = result.stdout + result.stderr
                if result.returncode == 0 or diagnostic not in output:
                    raise SystemExit(f'{receiver}: expected conversion argument rejection\n{output}')
            print(f'PASS: {receiver}: convert uses to URL/as format; old labels and omitted format rejected', flush=True)

        for module, extra in [('SwiftSheets', ''), ('SheetEncrypt', ', password: "test"')]:
            prefix = f'import Foundation\nimport {module}\nfunc probe(_ workbook: Workbook) throws {{\n'
            # Check both the default options and the explicit-options spelling independently.
            for options in ['', ', options: WriteOptions()']:
                arguments = f'as: .xlsx{options}{extra}'
                source.write_text(prefix + f'    let _: Data = try workbook.data({arguments})\n}}\n')
                result = subprocess.run(command, text=True, capture_output=True)
                output = result.stdout + result.stderr
                if result.returncode == 0 or "has no member 'data'" not in output:
                    raise SystemExit(f'{module}: removed data API is still reachable or failed for another reason\n{output}')
                source.write_text(prefix + f'    let _: Data = try workbook.write({arguments}).data\n'
                                  + f'    let result = try workbook.write({arguments})\n'
                                  + '    print(result.warnings, result.suggestion as Any)\n}\n')
                result = subprocess.run(command + ['-warnings-as-errors'], text=True, capture_output=True)
                if result.returncode:
                    raise SystemExit(f'{module}: write replacement failed\n{result.stdout}{result.stderr}')
            print(f'PASS: {module}: data unavailable; write result and bytes compile', flush=True)


if __name__ == '__main__':
    main()
