"""Enumerates every test function in an openpyxl source tree and writes openpyxl-<version>-tests.json.

Usage: python enumerate_openpyxl_tests.py /path/to/openpyxl-3.1.5

The output is committed so that check.py can run without the openpyxl sources. One pytest function counts as one
test regardless of parametrization (a parametrized function maps to one Swift `@Test(arguments:)`)."""
import ast
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
pkg = root / "openpyxl"
version = (pkg / "_constants.py").read_text().split("__version__")[1].split('"')[1]
out = {"openpyxl": version, "files": []}
for path in sorted(pkg.rglob("tests/test_*.py")):
    tree = ast.parse(path.read_text(encoding="utf-8"))
    tests = []

    def visit(node, cls=None):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, ast.ClassDef):
                visit(child, child.name)
            elif isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)) and child.name.startswith("test"):
                params = 1
                for deco in child.decorator_list:
                    if isinstance(deco, ast.Call) and getattr(deco.func, "attr", "") == "parametrize" and len(deco.args) > 1:
                        arg = deco.args[1]
                        if isinstance(arg, (ast.List, ast.Tuple)):
                            params = max(params, len(arg.elts))
                tests.append({"name": child.name, "class": cls, "line": child.lineno, "params": params})

    visit(tree)
    # a name defined twice in one scope is one pytest test (the later definition wins)
    unique = {}
    for t in tests:
        unique[(t["class"], t["name"])] = t
    tests = list(unique.values())
    rel = path.relative_to(pkg).as_posix()
    module = "openpyxl" if rel.startswith("tests/") else rel.split("/tests/")[0]
    out["files"].append({"file": rel, "module": module, "tests": tests})
dest = pathlib.Path(__file__).with_name(f"openpyxl-{version}-tests.json")
dest.write_text(json.dumps(out, indent=1, ensure_ascii=False) + "\n")
print(f"{sum(len(f['tests']) for f in out['files'])} tests in {len(out['files'])} files → {dest.name}")
