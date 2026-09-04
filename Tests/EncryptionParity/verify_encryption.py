"""Independent readers for the files SwiftSheets protects (spec Appendix B.39.9).

    uv run --with msoffcrypto-tool --with cryptography python3 Tests/EncryptionParity/verify_encryption.py <dir> <password>

`<dir>` holds `protected.xlsx` and / or `protected.ods` written by SwiftSheets with `<password>`. The OOXML file is
decrypted by msoffcrypto-tool — a third-party implementation of [MS-OFFCRYPTO] that Excel-protected files are
routinely opened with — and the ODF file by the `cryptography` library following ODF 1.3 §4.3 step by step. Each
decrypted package is checked to be a ZIP and its first sheet part / content is printed as JSON, so the caller can
compare what came out with what went in. Exit 0 when every file present decrypted; 1 otherwise. Nothing here is
SwiftSheets' own code.
"""
import base64
import hashlib
import io
import json
import sys
import zipfile
import zlib
from pathlib import Path


def ooxml(path, password):
    import msoffcrypto
    with open(path, "rb") as f:
        office = msoffcrypto.OfficeFile(f)
        office.load_key(password=password)
        out = io.BytesIO()
        office.decrypt(out)
    out.seek(0)
    with zipfile.ZipFile(out) as z:
        names = z.namelist()
        sheet = z.read("xl/worksheets/sheet1.xml").decode("utf-8")
        strings = z.read("xl/sharedStrings.xml").decode("utf-8") if "xl/sharedStrings.xml" in names else ""
    return {"parts": len(names), "sheet1": sheet, "sharedStrings": strings}


def odf(path, password):
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
    from cryptography.hazmat.primitives import hashes

    import xml.etree.ElementTree as ET
    NS = "{urn:oasis:names:tc:opendocument:xmlns:manifest:1.0}"
    with zipfile.ZipFile(path) as z:
        root = ET.fromstring(z.read("META-INF/manifest.xml"))
        entries = {}
        for entry in root.iter(NS + "file-entry"):
            enc = entry.find(NS + "encryption-data")
            if enc is None:
                continue
            algorithm = enc.find(NS + "algorithm")
            kdf = enc.find(NS + "key-derivation")
            start = enc.find(NS + "start-key-generation")
            entries[entry.get(NS + "full-path")] = dict(
                size=int(entry.get(NS + "size")), checksum_type=enc.get(NS + "checksum-type"), checksum=enc.get(NS + "checksum"),
                algorithm=algorithm.get(NS + "algorithm-name"), iv=algorithm.get(NS + "initialisation-vector"),
                kdf=kdf.get(NS + "key-derivation-name"), key_size=int(kdf.get(NS + "key-size") or 32),
                iterations=int(kdf.get(NS + "iteration-count") or 1024), salt=kdf.get(NS + "salt"),
                start_key=start.get(NS + "start-key-generation-name") if start is not None else "#sha1")
        result = {"encrypted": sorted(entries)}
        for name, e in entries.items():
            assert e["algorithm"].endswith("#aes256-cbc"), e["algorithm"]
            assert e["kdf"] == "PBKDF2", e["kdf"]
            start = hashlib.sha256(password.encode("utf-8")).digest() if e["start_key"].endswith("#sha256") else hashlib.sha1(password.encode("utf-8")).digest()
            key = PBKDF2HMAC(algorithm=hashes.SHA1(), length=e["key_size"], salt=base64.b64decode(e["salt"]), iterations=e["iterations"]).derive(start)
            cipher = Cipher(algorithms.AES(key), modes.CBC(base64.b64decode(e["iv"]))).decryptor()
            plain = cipher.update(z.read(name)) + cipher.finalize()
            plain = plain[:-plain[-1]]
            digest = hashlib.sha256(plain[:1024]).digest() if e["checksum_type"].endswith("#sha256-1k") else hashlib.sha1(plain[:1024]).digest()
            assert digest == base64.b64decode(e["checksum"]), f"checksum of {name}"
            data = zlib.decompress(plain, -zlib.MAX_WBITS)
            assert len(data) == e["size"], f"size of {name}: {len(data)} vs {e['size']}"
            if name == "content.xml":
                result["content"] = data.decode("utf-8")
        return result


def main():
    directory, password = Path(sys.argv[1]), sys.argv[2]
    out = {}
    ok = True
    for name, reader in (("protected.xlsx", ooxml), ("protected.ods", odf)):
        path = directory / name
        if not path.exists():
            continue
        try:
            out[name] = reader(path, password)
        except Exception as e:  # the report is the point: say which file and why
            out[name] = {"error": f"{type(e).__name__}: {e}"}
            ok = False
    print(json.dumps(out, ensure_ascii=False))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
