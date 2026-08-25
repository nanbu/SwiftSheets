#!/usr/bin/env python3
"""Extracts the Numbers (IWA) schema SwiftSheets needs from numbers-parser (MIT, https://github.com/masaccio/numbers-parser)
into JSON resources under Sources/SheetNumbers/Resources/ — nothing is hand-copied (spec §10.1, Appendix B.8):

    registry.json   IWA message type id → fully qualified message name        (numbers_parser.generated.mapping.ID_NAME_MAP)
    constants.json  the integer constants Apple left unnamed in the Protobuf   (numbers_parser.constants: FormatType,
                    (number-format kinds, alignment, duration styles)          HorizontalJustification, VerticalJustification, DurationStyle, DurationUnits)
    functions.json  Numbers function id → name                                (numbers_parser.generated.functionmap.FUNCTION_MAP)
    schema.json     every Protobuf message: fields with number / type / label / message type / enum values
                    (the FileDescriptorProtos embedded in numbers_parser.generated.*_pb2)

Usage:  python3 scripts/extract-numbers-schema.py            # numbers_parser importable (e.g. a venv with numbers-parser)
        python3 scripts/extract-numbers-schema.py <site-packages or src dir containing numbers_parser/>
Record the numbers-parser version (printed) in the commit message and in NOTICE."""
import importlib
import json
import pathlib
import pkgutil
import sys

if len(sys.argv) > 1:
    sys.path.insert(0, sys.argv[1])
import numbers_parser  # noqa: E402
import numbers_parser.generated as generated  # noqa: E402
from google.protobuf import descriptor_pb2  # noqa: E402
from numbers_parser.generated.functionmap import FUNCTION_MAP  # noqa: E402
from numbers_parser.generated.mapping import ID_NAME_MAP  # noqa: E402
from numbers_parser import cell as np_cell  # noqa: E402
from numbers_parser import constants as np_constants  # noqa: E402

OUT = pathlib.Path(__file__).resolve().parents[1] / "Sources" / "SheetNumbers" / "Resources"
OUT.mkdir(parents=True, exist_ok=True)
version = getattr(numbers_parser, "__version__", None) or importlib.metadata.version("numbers-parser")

TYPE_NAMES = {1: "double", 2: "float", 3: "int64", 4: "uint64", 5: "int32", 6: "fixed64", 7: "fixed32", 8: "bool", 9: "string",
              10: "group", 11: "message", 12: "bytes", 13: "uint32", 14: "enum", 15: "sfixed32", 16: "sfixed64", 17: "sint32", 18: "sint64"}
LABELS = {1: "optional", 2: "required", 3: "repeated"}

messages = {}
enums = {}


def walk(package, prefix, msg):
    full = f"{prefix}.{msg.name}"
    fields = []
    for f in msg.field:
        entry = {"name": f.name, "number": f.number, "type": TYPE_NAMES[f.type], "label": LABELS[f.label]}
        if f.type in (11, 14, 10):
            entry["typeName"] = f.type_name.lstrip(".")
        if f.options.packed:
            entry["packed"] = True
        fields.append(entry)
    for ext in msg.extension:   # extensions declared inside a message extend another message
        extensions.setdefault(ext.extendee.lstrip("."), []).append(
            {"name": f"{full}.{ext.name}", "number": ext.number, "type": TYPE_NAMES[ext.type], "label": LABELS[ext.label],
             **({"typeName": ext.type_name.lstrip(".")} if ext.type in (11, 14) else {})})
    messages[full] = {"fields": fields}
    for e in msg.enum_type:
        enums[f"{full}.{e.name}"] = {v.name: v.number for v in e.value}
    for nested in msg.nested_type:
        walk(package, full, nested)


extensions = {}
for m in sorted(mi.name for mi in pkgutil.iter_modules(generated.__path__) if mi.name.endswith("_pb2")):
    mod = importlib.import_module(f"numbers_parser.generated.{m}")
    fd = descriptor_pb2.FileDescriptorProto.FromString(mod.DESCRIPTOR.serialized_pb)
    for msg in fd.message_type:
        walk(fd.package, fd.package, msg)
    for e in fd.enum_type:
        enums[f"{fd.package}.{e.name}"] = {v.name: v.number for v in e.value}
    for ext in fd.extension:
        extensions.setdefault(ext.extendee.lstrip("."), []).append(
            {"name": f"{fd.package}.{ext.name}", "number": ext.number, "type": TYPE_NAMES[ext.type], "label": LABELS[ext.label],
             **({"typeName": ext.type_name.lstrip(".")} if ext.type in (11, 14) else {})})
for extendee, exts in extensions.items():
    if extendee in messages:
        messages[extendee]["fields"].extend(exts)

# Constants Apple declared as plain int32 in the Protobuf, so the schema carries no names for them. numbers-parser
# recovered them; SwiftSheets reads them from there rather than transcribing the numbers into Swift by hand.
constants = {}
for name in ["FormatType", "HorizontalJustification", "VerticalJustification", "DurationStyle", "DurationUnits",
             "CellPadding", "CellType"]:
    enum = getattr(np_constants, name, None) or getattr(np_cell, name, None)
    if enum is None:
        continue
    try:
        constants[name] = {member.name: int(member.value) for member in enum}
    except TypeError:
        continue

registry = {str(k): v.DESCRIPTOR.full_name for k, v in ID_NAME_MAP.items()}
functions = {str(k): v for k, v in FUNCTION_MAP.items()}
meta = {"source": "numbers-parser", "version": version, "license": "MIT",
        "note": "machine-extracted by scripts/extract-numbers-schema.py — do not edit by hand"}
(OUT / "registry.json").write_text(json.dumps({"_meta": meta, "types": registry}, indent=1, sort_keys=True) + "\n")
(OUT / "functions.json").write_text(json.dumps({"_meta": meta, "functions": functions}, indent=1, sort_keys=True) + "\n")
(OUT / "constants.json").write_text(json.dumps({"_meta": meta, "constants": constants}, indent=1, sort_keys=True) + "\n")
(OUT / "schema.json").write_text(json.dumps({"_meta": meta, "messages": messages, "enums": enums}, indent=1, sort_keys=True) + "\n")
print(f"numbers-parser {version}: {len(registry)} registry types, {len(functions)} functions, {len(messages)} messages, "
      f"{len(enums)} enums, {len(constants)} constant groups → {OUT}")
