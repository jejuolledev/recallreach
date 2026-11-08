"""GS1 DataMatrix parser for US drug packages (DSCSA).

A 2D barcode on a US prescription drug box carries four Application
Identifiers: (01) GTIN-14, (17) expiry YYMMDD, (10) lot, (21) serial.
Scanners deliver either the human-readable form "(01)...(17)..." or the raw
form with the ASCII Group Separator (0x1D) after variable-length fields.
"""
import datetime
import re

from . import ndc as ndcmod

GS = "\x1d"
FIXED = {"01": 14, "17": 6, "11": 6, "15": 6}
VARIABLE = {"10": 20, "21": 20}


class GS1Error(ValueError):
    pass


def _normalize(raw):
    s = (raw or "").strip()
    # common textual stand-ins for the group separator
    for token in ("<GS>", "{GS}", "\\x1d", "^]", "␝"):
        s = s.replace(token, GS)
    if s.startswith("]d2") or s.startswith("]D2"):
        s = s[3:]
    return s


def parse(raw):
    s = _normalize(raw)
    if not s:
        raise GS1Error("empty barcode")
    fields = {}
    if "(" in s:
        for ai, val in re.findall(r"\((\d{2})\)([^(]*)", s):
            fields[ai] = val.replace(GS, "").strip()
    else:
        i = 0
        while i < len(s):
            if s[i] == GS:
                i += 1
                continue
            ai = s[i:i + 2]
            i += 2
            if ai in FIXED:
                n = FIXED[ai]
                fields[ai] = s[i:i + n]
                i += n
            elif ai in VARIABLE:
                j = s.find(GS, i)
                if j < 0:
                    j = len(s)
                fields[ai] = s[i:j][:VARIABLE[ai]]
                i = j
            else:
                raise GS1Error("unknown application identifier '%s' at position %d" % (ai, i - 2))
    if "01" not in fields:
        raise GS1Error("no GTIN (01) found")
    gtin = fields["01"]
    if not re.fullmatch(r"\d{14}", gtin):
        raise GS1Error("GTIN must be 14 digits")
    out = {
        "gtin": gtin,
        "gtin_check_ok": ndcmod.gtin_check_digit_ok(gtin),
        "lot": fields.get("10", ""),
        "serial": fields.get("21", ""),
        "expiry": "",
    }
    ten, cands = ndcmod.from_gtin14(gtin)
    out["ndc10"] = ten or ""
    out["ndc11_candidates"] = cands
    if "17" in fields:
        out["expiry"] = expiry_to_iso(fields["17"])
    return out


def expiry_to_iso(yymmdd):
    if not re.fullmatch(r"\d{6}", yymmdd or ""):
        raise GS1Error("expiry must be YYMMDD")
    yy, mm, dd = int(yymmdd[:2]), int(yymmdd[2:4]), int(yymmdd[4:])
    year = 2000 + yy
    if dd == 0:  # GS1: day 00 means end of month
        nxt = datetime.date(year + (mm // 12), mm % 12 + 1, 1)
        d = nxt - datetime.timedelta(days=1)
    else:
        d = datetime.date(year, mm, dd)
    return d.isoformat()


def build(ndc11, lot, expiry_iso, serial):
    """Make a human-readable GS1 string for a given NDC (used by the demo 'print label')."""
    # 11-digit back to 10 digits: drop the padding zero.  We cannot know which
    # zero was padding without the layout, so try 5-4-1 / 5-3-2 / 4-4-2 order
    # by preference of the original labeler length.
    ten = None
    if ndc11[0] == "0":
        ten = ndc11[1:]
    elif ndc11[5] == "0":
        ten = ndc11[:5] + ndc11[6:]
    elif ndc11[9] == "0":
        ten = ndc11[:9] + ndc11[10:]
    if ten is None:
        raise GS1Error("cannot map this NDC to a 10-digit GTIN body")
    body = "003" + ten
    total = 0
    for i, ch in enumerate(reversed(body)):
        total += int(ch) * (3 if i % 2 == 0 else 1)
    gtin = body + str((10 - total % 10) % 10)
    y, m, d = expiry_iso.split("-")
    return "(01)%s(17)%s%s%s(10)%s(21)%s" % (gtin, y[2:], m, d, lot, serial)
