"""NDC helpers.

FDA prints NDCs in three hyphenated layouts (4-4-2, 5-3-2, 5-4-1).
Billing systems (and MIMIC-IV) store an 11-digit 5-4-2 form with no hyphens.
"""
import re

NDC_IN_TEXT = re.compile(r"(?<![\d-])(\d{4,5}-\d{3,4}-\d{1,2})(?![\d-])")


def to_11(ndc):
    """Return the 11-digit 5-4-2 form, or None if the input is not a valid NDC."""
    if ndc is None:
        return None
    s = str(ndc).strip()
    parts = s.split("-")
    if len(parts) == 3:
        a, b, c = parts
        if not (a.isdigit() and b.isdigit() and c.isdigit()):
            return None
        if (len(a), len(b), len(c)) == (4, 4, 2):
            a = "0" + a
        elif (len(a), len(b), len(c)) == (5, 3, 2):
            b = "0" + b
        elif (len(a), len(b), len(c)) == (5, 4, 1):
            c = "0" + c
        elif (len(a), len(b), len(c)) != (5, 4, 2):
            return None
        return a + b + c
    digits = re.sub(r"\D", "", s)
    if len(digits) == 11 and len(parts) == 1:
        return digits
    return None


def product_code(ndc11):
    """Labeler + product (first 9 digits): same drug product, any package size."""
    return ndc11[:9] if ndc11 and len(ndc11) == 11 else None


def pretty(ndc11):
    if not ndc11 or len(ndc11) != 11:
        return ndc11 or ""
    return "%s-%s-%s" % (ndc11[:5], ndc11[5:9], ndc11[9:])


def find_in_text(text):
    """All NDCs written in free text, with character spans: [(ndc11, start, end, raw)]."""
    out = []
    for m in NDC_IN_TEXT.finditer(text or ""):
        n = to_11(m.group(1))
        if n:
            out.append((n, m.start(1), m.end(1), m.group(1)))
    return out


def from_gtin14(gtin):
    """US GTIN-14 for drugs = indicator(1) + '03' + 10-digit NDC + check digit.

    The 10-digit NDC has no hyphens, so the 5-4-2 layout is ambiguous.  We
    return the 10 digits and the candidate 11-digit forms; the caller picks the
    one that exists in its records.
    """
    g = re.sub(r"\D", "", gtin or "")
    if len(g) != 14 or not g[1:3] == "03":
        return None, []
    ten = g[3:13]
    cands = [
        "0" + ten,                      # 4-4-2
        ten[:5] + "0" + ten[5:],        # 5-3-2
        ten[:9] + "0" + ten[9:],        # 5-4-1
    ]
    return ten, cands


def gtin_check_digit_ok(gtin):
    g = re.sub(r"\D", "", gtin or "")
    if len(g) != 14:
        return False
    total = 0
    for i, ch in enumerate(reversed(g[:-1])):
        total += int(ch) * (3 if i % 2 == 0 else 1)
    return (10 - total % 10) % 10 == int(g[-1])
