#!/usr/bin/env python3
"""Offline checks for current support wording, fixture provenance and real HTML links. --self-test tests detection.

Archive metadata is checked separately by check-public-fixtures.py.
"""
import pathlib
import re
import sys
from html.parser import HTMLParser
from urllib.parse import unquote, urlsplit

ROOT = pathlib.Path(__file__).resolve().parents[1]

def stale_policy(text):
    return bool(re.search(r'SwiftSheets is pre-1\.0|latest 0\.x release|API is still moving before 1\.0', text))

class Links(HTMLParser):
    def __init__(self):
        super().__init__(); self.links = []; self.ids = []
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if 'id' in a: self.ids.append(a['id'])
        if tag in ('a', 'img', 'script', 'link'):
            u = a.get('href') if tag in ('a', 'link') else a.get('src')
            if u: self.links.append(u)

def check():
    errors = []
    policy_files = [ROOT / x for x in ('README.md', 'CONTRIBUTING.md', 'SECURITY.md', 'docs/api-stability.md')]
    for p in policy_files:
        if stale_policy(p.read_text()): errors.append(f'{p.relative_to(ROOT)} contains a pre-1.0 current policy')
    pages = sorted((ROOT / 'docs').glob('*.html'))
    if not pages: errors.append('No published HTML pages; cannot verify links')
    for p in pages:
        parser = Links(); parser.feed(p.read_text())
        if len(set(parser.ids)) != len(parser.ids): errors.append(f'{p.name}: duplicate HTML IDs')
        for link in parser.links:
            u = urlsplit(link)
            if u.scheme or u.netloc: continue
            target = p.parent / unquote(u.path) if u.path else p
            if not target.exists(): errors.append(f'{p.name}: missing local target {link}'); continue
            if u.fragment and target.suffix == '.html':
                q = Links(); q.feed(target.read_text())
                if unquote(u.fragment) not in q.ids: errors.append(f'{p.name}: missing anchor {link}')
    fixtures = sorted((ROOT / 'Tests/SwiftSheetsTests/Fixtures/numbers').glob('*.numbers'))
    if not fixtures: errors.append('No Numbers fixtures; cannot verify provenance')
    ledger = (ROOT / 'Tests/SwiftSheetsTests/Fixtures/numbers/PROVENANCE.md').read_text()
    names = re.findall(r'^\| `([^`]+\.numbers)` \|', ledger, re.M)
    if sorted(names) != [p.name for p in fixtures]: errors.append('Numbers provenance ledger differs from fixture set')
    return errors

if '--self-test' in sys.argv:
    assert stale_policy('The latest 0.x release.')
    assert not stale_policy('The latest 1.x release.')
    p = Links(); p.feed('<pre>&lt;a href="Pictures/…"&gt;</pre><a href="index.html">link</a>')
    assert p.links == ['index.html']
    print('Public-document detector self-test passed')
else:
    errors = check()
    if errors: print('\n'.join(errors)); raise SystemExit(1)
    print('Current policies, HTML links and Numbers fixture provenance are consistent')
