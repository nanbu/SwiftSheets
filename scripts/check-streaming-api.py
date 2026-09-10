#!/usr/bin/env python3
"""Compile an external client against the row-by-row writer's save contract (spec B.51).

No @testable and no package identity: what this proves has to survive the exported modules.

Positive: close() and withStreamingWriter hand back a StreamingWriteResult that must be used or explicitly
discarded; cancel(); StreamingCleanupError's two halves; both ways in (the umbrella's StreamingWriter(to:) and
a CodecSet of whichever codecs are linked).
Negative: the result and the error cannot be made up by a caller, close() is no longer Void, and the pieces the
save is built from (the sink, the temporary file) stay inside the package.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

# (name, imports, how the writer is made) — the umbrella's convenience and any set of codecs reach the same writer
WRITERS = [
    ('SwiftSheets', 'import SwiftSheets', 'try StreamingWriter(to: url)'),
    ('CodecSet', 'import SheetCore\nimport SheetXLSX', 'try CodecSet([.xlsx]).streamingWriter(to: url)'),
]


def main():
    subprocess.run(['swift', 'build'], cwd=ROOT, check=True)
    binary = Path(subprocess.check_output(['swift', 'build', '--show-bin-path'], cwd=ROOT, text=True).strip())
    with tempfile.TemporaryDirectory(prefix='swiftsheets-streaming-') as tmp:
        source = Path(tmp) / 'Client.swift'
        command = ['swiftc', '-typecheck', '-I', str(binary / 'Modules'),
                   '-I', str(ROOT / 'Sources/CZlib'), str(source)]

        def compile(text, strict=False):
            source.write_text(text)
            result = subprocess.run(command + (['-warnings-as-errors'] if strict else []), text=True, capture_output=True)
            return result.returncode, result.stdout + result.stderr

        # 1. the save's answer is not discardable, whichever way the writer was made
        for name, imports, make in WRITERS:
            prefix = f'import Foundation\n{imports}\nfunc probe(_ url: URL) throws {{\n    let writer = {make}\n'
            for strict in [False, True]:
                code, output = compile(prefix + '    try writer.close()\n}\n', strict)
                diagnostic = 'error:' if strict else 'warning:'
                if ((code != 0) != strict or diagnostic not in output
                        or 'result of call to' not in output or 'is unused' not in output):
                    raise SystemExit(f'{name}.close: expected unused-result {diagnostic}\n{output}')
            code, output = compile(prefix + '    _ = try writer.close()\n'
                                   + f'    let writer2 = {make}\n'
                                   + '    let result = try writer2.close()\n'
                                   + '    print(result.format, result.warnings)\n'
                                   + f'    let writer3 = {make}\n'
                                   + '    try writer3.cancel()\n}\n', strict=True)
            if code:
                raise SystemExit(f'{name}: using the result, discarding it, and cancelling must all compile\n{output}')
            print(f'PASS: {name}: close() warns when its result is dropped, and cancel() exists', flush=True)

        # 2. close() is no longer Void: a caller who typed it that way is told, rather than silently kept
        code, output = compile('import Foundation\nimport SwiftSheets\n'
                               'func probe(_ url: URL) throws {\n    let v: Void = try StreamingWriter(to: url).close()\n    print(v)\n}\n')
        if code == 0:
            raise SystemExit(f'close() still type-checks as Void\n{output}')
        print('PASS: close() no longer returns Void', flush=True)

        # 3. the managed form: the closure's writer, the result, and the same unused-result rule
        managed = ('import Foundation\nimport SwiftSheets\n'
                   'func probe(_ url: URL) throws {\n'
                   '    let result = try CodecSet.all.withStreamingWriter(to: url, as: .xlsx, sheetName: "S") { writer in\n'
                   '        try writer.append([.text("a"), .integer(1)])\n'
                   '        try writer.addSheet(named: "Two")\n'
                   '    }\n'
                   '    print(result.format, result.warnings)\n'
                   '    _ = try CodecSet.all.withStreamingWriter(to: url) { _ in }\n}\n')
        code, output = compile(managed, strict=True)
        if code:
            raise SystemExit(f'withStreamingWriter does not compile as documented\n{output}')
        code, output = compile('import Foundation\nimport SwiftSheets\n'
                               'func probe(_ url: URL) throws {\n'
                               '    try CodecSet.all.withStreamingWriter(to: url) { _ in }\n}\n')
        if code != 0 or 'is unused' not in output:
            raise SystemExit(f'withStreamingWriter: expected an unused-result warning\n{output}')
        print('PASS: withStreamingWriter takes to:/as: and its result is not discardable', flush=True)

        # 4. the double failure keeps both halves, and a caller reads them
        code, output = compile('import Foundation\nimport SwiftSheets\n'
                               'func probe(_ url: URL) throws {\n'
                               '    do { _ = try StreamingWriter(to: url).close() }\n'
                               '    catch let failure as StreamingCleanupError { print(failure.primaryError, failure.cleanupErrors) }\n}\n',
                               strict=True)
        if code:
            raise SystemExit(f'StreamingCleanupError is not readable from outside\n{output}')
        print('PASS: StreamingCleanupError carries the cause and the cleanup failures', flush=True)

        # 5. what stays inside the package: no made-up results, no reaching the parts the save is built from
        for name, snippet, expected in [
            ('StreamingWriteResult.init', 'let r = StreamingWriteResult(format: .xlsx, warnings: [])\n    print(r)', ['is inaccessible', 'cannot find', 'extra argument', 'no exact matches']),
            ('StreamingCleanupError.init', 'let e = StreamingCleanupError(primaryError: SheetError.wrongPassword, cleanupErrors: [])\n    print(e)', ['is inaccessible', 'cannot find', 'extra argument', 'no exact matches']),
            ('AtomicFileTarget', '_ = AtomicFileTarget.self', ['cannot find', 'inaccessible']),
            ('StreamingRowSink', 'let _: any StreamingRowSink.Type = nil', ['cannot find', 'inaccessible']),
            ('StreamingWriter.sink', 'let w = try StreamingWriter(to: url)\n    print(w.sink)', ['inaccessible', 'has no member']),
        ]:
            code, output = compile(f'import Foundation\nimport SwiftSheets\nfunc probe(_ url: URL) throws {{\n    {snippet}\n}}\n')
            if code == 0 or not any(reason in output for reason in expected):
                raise SystemExit(f'{name}: expected to be out of reach from outside the package\n{output}')
            print(f'PASS: {name} is not part of the public surface', flush=True)


if __name__ == '__main__':
    main()
