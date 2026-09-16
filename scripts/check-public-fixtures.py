#!/usr/bin/env python3
"""Check fixture archive metadata without printing matched personal values. --self-test validates detection.

Licence/NOTICE attribution and Git authorship are intentionally outside this check.
IWA strings are inspected as bytes, not decoded as a complete Protobuf object graph.
"""
import io
import pathlib
import re
import subprocess
import sys
import zipfile
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
HOME_PATH = re.compile(rb'(?:/Users/|/home/)[^/\s<>"\x00]+/')

def check_member(file, member, data):
    errors = []
    if any(m.group(0) != b'/home/user/' for m in HOME_PATH.finditer(data)): errors.append(f'{file}: {member}: home-directory path in archive payload')
    if member == 'docProps/core.xml':
        root = ET.fromstring(data)
        authors = [n.text or '' for n in root if n.tag.rsplit('}', 1)[-1] in ('creator', 'lastModifiedBy')]
        expected = 'Shinichi Nambu' if file == 'Tests/SwiftSheetsTests/Fixtures/chartsheet.xlsx' else 'openpyxl fixture'
        if file == 'Tests/SwiftSheetsTests/Fixtures/chartsheet.xlsx':
            invalid = authors != [expected, expected]
        else:
            invalid = '/Fixtures/openpyxl/' in file and any(a and a != expected for a in authors)
        if invalid:
            errors.append(f'{file}: {member}: missing or unexpected fixture author metadata')
    return errors

if '--self-test' in sys.argv:
    assert HOME_PATH.search(b'<absPath url="/Users/' + b'example/project/"/>')
    assert not HOME_PATH.search(b'<absPath url="/fixtures/"/>')
    assert not check_member('synthetic', 'content.xml', b'file:///home/user/Budget.ods')
    assert check_member('Tests/SwiftSheetsTests/Fixtures/chartsheet.xlsx', 'docProps/core.xml',
                        b'<core><creator>Other</creator></core>')
    assert not check_member('Tests/SwiftSheetsTests/Fixtures/chartsheet.xlsx', 'docProps/core.xml',
                            b'<core><creator>Shinichi Nambu</creator><lastModifiedBy>Shinichi Nambu</lastModifiedBy></core>')
    print('Fixture metadata detector self-test passed')
    raise SystemExit(0)
files = subprocess.check_output(['git', 'ls-files', 'Tests/SwiftSheetsTests/Fixtures', 'Sources/SheetNumbers/Resources'], cwd=ROOT, text=True).splitlines()
if not files: raise SystemExit('Fixture set is empty; cannot verify metadata')
errors = []; archives = 0
for file in files:
    p = ROOT / file
    if not zipfile.is_zipfile(p): continue
    archives += 1
    with zipfile.ZipFile(p) as z:
        for member in z.namelist():
            if z.getinfo(member).file_size > 5_000_000: raise SystemExit(f'{file}: oversized member; metadata check incomplete')
            errors.extend(check_member(file, member, z.read(member)))
if not archives: raise SystemExit('No fixture archives; cannot verify metadata')
if errors: print('\n'.join(errors)); raise SystemExit(1)
print(f'Checked {archives} fixture/resource archives; no home paths or unexpected fixture author metadata')
