"""Build the deterministic, entirely synthetic consumer-contract XLSX specimen."""
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[2]
DESTINATION = ROOT / "Tests/SwiftSheetsTests/Fixtures/interop/consumer-contract.xlsx"
S = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
A = "http://schemas.openxmlformats.org/drawingml/2006/main"
XDR = "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing"
GUID = "{bdbb8cdc-fa1e-496e-a857-3c3f30c029c3}"


def marker(tag, col, row, x=31750, y=31750):
    return (f"<xdr:{tag}><xdr:col>{col}</xdr:col><xdr:colOff>{x}</xdr:colOff>"
            f"<xdr:row>{row}</xdr:row><xdr:rowOff>{y}</xdr:rowOff></xdr:{tag}>")


def shape(identity, name, text="", extra=""):
    return (f'<xdr:sp><xdr:nvSpPr><xdr:cNvPr id="{identity}" name="{name}"/>'
            '<xdr:cNvSpPr txBox="1"/></xdr:nvSpPr><xdr:spPr>'
            '<a:xfrm rot="1800000" flipH="1"><a:off x="31750" y="63500"/>'
            '<a:ext cx="1270000" cy="635000"/></a:xfrm>'
            '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>'
            f'{extra}</xdr:spPr>{text}</xdr:sp>')


TEXT = ('<xdr:txBody><a:bodyPr lIns="31750" tIns="63500" rIns="95250" bIns="127000" '
        'vert="vert" anchor="ctr"/><a:lstStyle/><a:p><a:pPr algn="ctr"/>'
        '<a:r><a:rPr b="1"><a:solidFill><a:srgbClr val="FF0000"/></a:solidFill>'
        '<a:latin typeface="+mj-lt"/></a:rPr><a:t>日本語</a:t></a:r>'
        '<a:r><a:rPr i="1"><a:solidFill><a:schemeClr val="accent1"/></a:solidFill>'
        '<a:ea typeface="+mn-ea"/></a:rPr><a:t> mixed</a:t></a:r><a:br/></a:p>'
        '<a:p><a:pPr algn="r"/><a:r><a:t>Second paragraph</a:t></a:r></a:p></xdr:txBody>')
GROUP_PROPERTIES = ('<xdr:grpSpPr><a:xfrm rot="1800000" flipH="1">'
                    '<a:off x="31750" y="63500"/><a:ext cx="1270000" cy="635000"/>'
                    '<a:chOff x="0" y="0"/><a:chExt cx="1000" cy="500"/>'
                    '</a:xfrm></xdr:grpSpPr>')
GROUP = ('<xdr:grpSp><xdr:nvGrpSpPr><xdr:cNvPr id="1" name="Outer group"/>'
         '<xdr:cNvGrpSpPr/></xdr:nvGrpSpPr>' + GROUP_PROPERTIES +
         '<xdr:grpSp><xdr:nvGrpSpPr><xdr:cNvPr id="2" name="Inner group"/>'
         '<xdr:cNvGrpSpPr/></xdr:nvGrpSpPr>' + GROUP_PROPERTIES +
         shape(3, "Grouped text", TEXT) + '</xdr:grpSp></xdr:grpSp>')
DRAWING = (f'<xdr:wsDr xmlns:xdr="{XDR}" xmlns:a="{A}" xmlns:r="{R}">'
           '<xdr:oneCellAnchor>' + marker("from", 1, 4) +
           '<xdr:ext cx="1270000" cy="635000"/>' + GROUP +
           '<xdr:clientData/></xdr:oneCellAnchor>'
           '<xdr:absoluteAnchor><xdr:pos x="31750" y="63500"/>'
           '<xdr:ext cx="1270000" cy="635000"/>' +
           shape(4, "Mixed text", TEXT, '<a:effectLst><a:outerShdw blurRad="12700" dist="12700" '
                 'dir="0"><a:srgbClr val="000000"><a:alpha val="50000"/></a:srgbClr>'
                 '</a:outerShdw></a:effectLst>') + '<xdr:clientData/></xdr:absoluteAnchor>'
           '<xdr:twoCellAnchor editAs="oneCell">' + marker("from", 4, 4) +
           marker("to", 6, 7, 63500, 95250) + shape(5, "Fractional range") +
           '<xdr:clientData/></xdr:twoCellAnchor></xdr:wsDr>')


def dynamic_record(flag):
    return (f'<bk><extLst><ext uri="{GUID}"><xda:dynamicArrayProperties '
            f'fDynamic="{flag}" fCollapsed="0"/></ext></extLst></bk>')


PARTS = {
    "[Content_Types].xml": '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Default Extension="bin" ContentType="application/octet-stream"/>'
    '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
    '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
    '<Override PartName="/xl/drawings/drawing1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>'
    '<Override PartName="/xl/metadata/arrays.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheetMetadata+xml"/>'
    '</Types>',
    "_rels/.rels": f'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    f'<Relationship Id="rId1" Type="{R}/officeDocument" Target="xl/workbook.xml"/></Relationships>',
    "xl/workbook.xml": f'<workbook xmlns="{S}" xmlns:r="{R}"><sheets>'
    '<sheet name="Interop" sheetId="1" r:id="rId1"/></sheets><calcPr fullCalcOnLoad="1"/></workbook>',
    "xl/_rels/workbook.xml.rels": '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    f'<Relationship Id="rId1" Type="{R}/worksheet" Target="worksheets/sheet1.xml"/>'
    f'<Relationship Id="rId2" Type="{R}/sheetMetadata" Target="metadata/arrays.xml"/>'
    '<Relationship Id="rId3" Type="urn:swiftsheets:synthetic:opaque" Target="custom/opaque.bin"/></Relationships>',
    "xl/worksheets/sheet1.xml": f'<worksheet xmlns="{S}" xmlns:r="{R}"><sheetData>'
    '<row r="1"><c r="A1"><v>1</v></c><c r="D1" cm="1"><f t="array" ref="D1:D2">'
    '_xlfn._xlws.FILTER(A1:A3,A1:A3&gt;1)</f><v>2</v></c>'
    '<c r="F1"><f>SUM(_xlfn.ANCHORARRAY(D1))</f><v>5</v></c>'
    '<c r="H1" cm="2"><f t="array" ref="H1:H2">SUM(A1:A3)</f><v>6</v></c></row>'
    '<row r="2"><c r="A2"><v>2</v></c><c r="D2"><v>3</v></c><c r="H2"><v>6</v></c></row>'
    '<row r="3"><c r="A3"><v>3</v></c></row><row r="5" hidden="1"/>'
    '</sheetData><drawing r:id="rId1"/></worksheet>',
    "xl/worksheets/_rels/sheet1.xml.rels": '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    f'<Relationship Id="rId1" Type="{R}/drawing" Target="../drawings/drawing1.xml"/></Relationships>',
    "xl/drawings/drawing1.xml": DRAWING,
    "xl/metadata/arrays.xml": f'<metadata xmlns="{S}" '
    'xmlns:xda="http://schemas.microsoft.com/office/spreadsheetml/2017/dynamicarray">'
    '<metadataTypes count="1"><metadataType name="XLDAPR" minSupportedVersion="120000" copy="1" '
    'pasteAll="1" pasteValues="1" merge="1" splitFirst="1" rowColShift="1" clearFormats="1" '
    'clearComments="1" assign="1" coerce="1" cellMeta="1"/></metadataTypes>'
    '<futureMetadata name="XLDAPR" count="2">' + dynamic_record(1) + dynamic_record(0) +
    '</futureMetadata><cellMetadata count="2"><bk><rc t="1" v="0"/></bk>'
    '<bk><rc t="1" v="1"/></bk></cellMetadata></metadata>',
    "xl/custom/opaque.bin": b"SwiftSheets synthetic opaque part\x00\x01\xff",
}


def generate(destination=DESTINATION):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(destination, "w", compression=ZIP_DEFLATED) as archive:
        for name, value in PARTS.items():
            info = ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = ZIP_DEFLATED
            archive.writestr(info, value.encode() if isinstance(value, str) else value)
    return destination


if __name__ == "__main__":
    print(generate())
