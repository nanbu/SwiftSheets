#!/usr/bin/env python3
"""The cookbook page from the code that CI compiles and runs — one source, one product.

    python3 scripts/build-cookbook.py            # rebuild docs/cookbook.md from Examples/Sources/swiftsheets-examples/Recipes
    python3 scripts/build-cookbook.py --check    # the page matches its source (CI; exit 1 on a difference)

Each recipe file starts with a comment block: the first line `// # Title`, the following `//` lines the prose,
then the code. The page shows the prose and the code exactly as compiled, so an example cannot rot — a recipe
that stops compiling fails `swift build --package-path Examples`, and one that stops working fails the run.
Standard library only.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RECIPES = os.path.join(ROOT, "Examples", "Sources", "swiftsheets-examples", "Recipes")
OUT = os.path.join(ROOT, "docs", "cookbook.md")

HEADER = """# SwiftSheets cookbook

Thirteen things people do with a spreadsheet library, each as a complete function that compiles and runs. The code
on this page **is** the code under [`Examples/`](../Examples/Sources/swiftsheets-examples/Recipes): the page is
generated from it (`scripts/build-cookbook.py`), CI builds the package on every push and runs every recipe on
macOS, so an example here cannot silently stop working.

Run one yourself, from a checkout:

```bash
swift run --package-path Examples swiftsheets-examples all /tmp/swiftsheets-cookbook
```

Every recipe takes a directory, writes what it makes there, and prints what it did. The helpers they share
(`makeSampleWorkbook`, a one-pixel PNG) are in `Support.swift` and exist only so each recipe runs on its own.
New to the library? Start with [Getting started](getting-started.md).

"""


def parse(path):
    prose, code = [], []
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    i = 0
    while i < len(lines) and lines[i].startswith("//"):
        prose.append(lines[i][2:].strip())
        i += 1
    while i < len(lines) and not lines[i].strip():
        i += 1
    code = "\n".join(lines[i:]).rstrip("\n")
    if not prose or not prose[0].startswith("# "):
        sys.exit("❌ %s does not start with a `// # Title` line" % os.path.relpath(path, ROOT))
    title = prose[0][2:].strip()
    body = "\n".join(prose[1:]).strip()
    body = re.sub(r"\n(?!\n)", " ", body)          # one paragraph per blank line
    return title, body, code


def render():
    files = sorted(f for f in os.listdir(RECIPES) if f.endswith(".swift"))
    out = [HEADER.rstrip("\n"), "", "## Contents", ""]
    parsed = [(f, *parse(os.path.join(RECIPES, f))) for f in files]
    for f, title, _, _ in parsed:
        anchor = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
        out.append("- [%s](#%s)" % (title, anchor))
    out.append("")
    for f, title, body, code in parsed:
        out.append("## %s" % title)
        out.append("")
        out.append(body)
        out.append("")
        out.append("_[`%s`](../Examples/Sources/swiftsheets-examples/Recipes/%s)_" % (f, f))
        out.append("")
        out.append("```swift")
        out.append(code)
        out.append("```")
        out.append("")
    return "\n".join(out).rstrip("\n") + "\n"


def main():
    page = render()
    if "--check" in sys.argv[1:]:
        try:
            with open(OUT, encoding="utf-8") as fh:
                current = fh.read()
        except FileNotFoundError:
            current = None
        if current != page:
            print("❌ docs/cookbook.md does not match Examples/ — run python3 scripts/build-cookbook.py", file=sys.stderr)
            return 1
        print("✅ docs/cookbook.md matches its source (%d recipes)" % (page.count("\n## ") - 1))
        return 0
    with open(OUT, "w", encoding="utf-8") as fh:
        fh.write(page)
    print("✅ docs/cookbook.md (%d B)" % len(page.encode("utf-8")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
