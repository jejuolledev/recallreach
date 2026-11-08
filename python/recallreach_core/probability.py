"""Estimated probability that a patient received a unit from the recalled lot(s).

P(dispense) = product_match x time_overlap x lot_share x region
P(patient)  = 1 - prod(1 - P(dispense))        (several fills -> more chances)

If the dispense has a barcode-scanned lot, the answer is exact: 1.0 when the lot
is on the recall, 0.0 when it is not.  Everything else is an ESTIMATE and is
labelled as such in the UI with the numbers and sources used.
"""
import datetime as dt
import re

from . import ndc as ndcmod

SHELF_LIFE_MONTHS = 24          # assumption, shown in the UI
HEURISTIC_NO_VOLUME = 0.5       # lot share when no public volume data is available
WRONG_NDC_RATE = 0.02           # same ingredient+strength but different NDC on record
OTHER_STRENGTH = 0.005          # same ingredient, different strength
NO_NDC_SAME_STRENGTH = 0.25     # record has no NDC: assume 1 of ~4 labelers
REGION_OUTSIDE = 0.05
REGION_UNKNOWN = 0.7
DEFAULT_THRESHOLD = 0.05
PHARMACY_STATE = "MA"           # MIMIC-IV comes from Beth Israel Deaconess, Boston


def _date(s):
    if not s:
        return None
    s = str(s)[:10]
    if re.fullmatch(r"\d{8}", s):
        s = "%s-%s-%s" % (s[:4], s[4:6], s[6:])
    try:
        return dt.date.fromisoformat(s)
    except ValueError:
        return None


def _add_months(d, n):
    y, m = divmod(d.month - 1 + n, 12)
    y += d.year
    m += 1
    day = min(d.day, [31, 29 if y % 4 == 0 and (y % 100 != 0 or y % 400 == 0) else 28,
                      31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1])
    return dt.date(y, m, day)


def real_date_window(shifted_ts, anchor_year, anchor_year_group):
    """MIMIC shifts every date; anchor_year maps to some year inside the 3-year
    anchor_year_group.  So the real dispense date lies in a ~3 year window."""
    d = _date(shifted_ts)
    if d is None:
        return None, None
    g0, g1 = [int(x) for x in str(anchor_year_group).split("-")]
    off = d.year - int(anchor_year)
    try:
        lo = d.replace(year=g0 + off)
        hi = d.replace(year=g1 + 1 + off)
    except ValueError:  # Feb 29
        lo = (d - dt.timedelta(days=1)).replace(year=g0 + off)
        hi = (d - dt.timedelta(days=1)).replace(year=g1 + 1 + off)
    return lo, hi


def lot_window(extraction, recall):
    """When could the recalled lot(s) have been on the shelf?"""
    init = _date(recall.get("recall_initiation_date")) or _date(recall.get("report_date"))
    exps = [_date(l.get("expiry")) for l in extraction.get("lots", []) if l.get("expiry")]
    exps = [e for e in exps if e]
    if exps:
        start = _add_months(min(exps), -SHELF_LIFE_MONTHS)
        end = min(max(exps), init) if init else max(exps)
        basis = "lot expiry %s minus %d-month shelf life, until the recall started" % (
            min(exps).isoformat(), SHELF_LIFE_MONTHS)
    elif init:
        start, end = _add_months(init, -SHELF_LIFE_MONTHS), init
        basis = "%d months before the recall started (no expiry printed)" % SHELF_LIFE_MONTHS
    else:
        return None, None, "no dates in notice"
    if end < start:
        end = start
    return start, end, basis


def overlap(lo, hi, a, b):
    if not (lo and hi and a and b) or hi <= lo:
        return 0.0
    days = (min(hi, b) - max(lo, a)).days
    return max(0.0, days / float((hi - lo).days))


def units_per_container(description):
    d = description or ""
    n = re.search(r"(\d+)[- ]count", d, re.I)
    base = int(n.group(1)) if n else None
    if base is None:
        m = re.search(r"(\d+)\s*(?:tablets|capsules|caplets)\s*(?:per|/|in a|in)\s*(?:bottle|carton|card|pack)", d, re.I)
        base = int(m.group(1)) if m else None
    mult = re.search(r"(\d+)\s*(?:blister packs?|blister cards?|cards|bottles|packs?)\s*(?:per|/|in a)\s*carton", d, re.I)
    if base and mult:
        return base * int(mult.group(1))
    return base


def recalled_units(recall):
    """First number in product_quantity x units per container (if we can read it)."""
    q = recall.get("product_quantity") or ""
    nums = re.findall(r"(\d[\d,]*)\s*(?:[A-Za-z][A-Za-z ]{0,30})?", q)
    nums = [int(n.replace(",", "")) for n in nums if n.replace(",", "").isdigit()]
    # "a) 42,733 cartons; b) 3,267 cartons" -> sum of the parts
    parts = re.findall(r"(\d[\d,]*)\s*(?:cartons?|bottles?|bags?|vials?|units?|containers?|boxes|packs?|inhalers?|tubes?|cards?|cups?)", q, re.I)
    if parts:
        containers = sum(int(n.replace(",", "")) for n in parts)
    elif nums:
        containers = nums[0]
    else:
        return None, None, q
    per = units_per_container(recall.get("product_description"))
    return containers, per, q


def _quarters(a, b):
    out = []
    y, q = a.year, (a.month - 1) // 3 + 1
    while (y, q) <= (b.year, (b.month - 1) // 3 + 1):
        out.append("%dQ%d" % (y, q))
        q += 1
        if q == 5:
            y, q = y + 1, 1
    return out


def lot_share(recall, extraction, ndcs11, sdud, win):
    """Recalled quantity / dispensed volume for that NDC in the lot window.

    Volume = CMS Medicaid State Drug Utilization Data (national, units
    reimbursed).  Medicaid is only part of the market, so the ratio over-states
    the share; we cap at 100% and say so.
    """
    if extraction.get("all_lots"):
        return 1.0, {"basis": "notice says all lots are recalled", "source": "FDA notice"}
    containers, per, raw = recalled_units(recall)
    a, b = win[0], win[1]
    solid = re.search(r"\btablets?\b|\bcapsules?\b|\bcaplets?\b", recall.get("product_description") or "", re.I)
    if not (solid and per):
        return HEURISTIC_NO_VOLUME, {
            "basis": "Medicaid volume for this form is counted in mL/g, not packages, so it is not comparable: heuristic %d%%"
                     % (HEURISTIC_NO_VOLUME * 100),
            "source": "heuristic",
        }
    vol, rows, suppressed = 0.0, 0, 0
    if sdud and a and b:
        qs = set(_quarters(a, b))
        for n in ndcs11:
            for qk, v in (sdud.get(n) or {}).items():
                if qk in qs:
                    if v is None:
                        suppressed += 1
                    else:
                        vol += float(v)
                        rows += 1
    if containers and rows and vol > 0:
        units = containers * (per or 1)
        ratio = units / vol
        share = min(1.0, ratio)
        return share, {
            "basis": "recalled %s%s = %s units vs %s Medicaid units dispensed for this NDC in %s..%s%s"
                     % (raw, (" x %d per container" % per) if per else "", "{:,}".format(units),
                        "{:,.0f}".format(vol), a.isoformat(), b.isoformat(),
                        "; capped at 100%" if ratio > 1 else ""),
            "caveat": "Medicaid covers only part of US dispensing, so the real share is lower than this ratio.",
            "source": "openFDA product_quantity + CMS Medicaid State Drug Utilization Data",
            "suppressed_quarters": suppressed,
        }
    return HEURISTIC_NO_VOLUME, {
        "basis": "no public volume data for this NDC in the window: heuristic %d%%" % (HEURISTIC_NO_VOLUME * 100),
        "source": "heuristic",
    }


def region_factor(extraction):
    if extraction.get("nationwide"):
        return 1.0, "distributed nationwide"
    st = extraction.get("states") or []
    if not st:
        return REGION_UNKNOWN, "distribution not stated (heuristic %d%%)" % (REGION_UNKNOWN * 100)
    if PHARMACY_STATE in st:
        return 1.0, "distributed to %s" % PHARMACY_STATE
    return REGION_OUTSIDE, "not distributed to %s (heuristic %d%%)" % (PHARMACY_STATE, REGION_OUTSIDE * 100)


def _norm_strength(s):
    s = (s or "").lower().replace(" ", "").replace(",", "")
    m = re.match(r"(\d+(?:\.\d+)?)(mg|mcg|g|meq|units?|%|ml)", s)
    if not m:
        return s
    v = float(m.group(1))
    unit = m.group(2)
    if unit == "g":
        v, unit = v * 1000, "mg"
    if unit == "mcg":
        v, unit = v / 1000, "mg"
    return "%g%s" % (v, unit)


def product_factor(extraction, dispense):
    rec = set(extraction.get("ndcs") or [])
    rec_prod = {ndcmod.product_code(n) for n in rec}
    d_ndc = dispense.get("ndc") or ""
    if d_ndc and d_ndc in rec:
        return 1.0, "ndc", "NDC %s is on the recall" % ndcmod.pretty(d_ndc)
    if d_ndc and ndcmod.product_code(d_ndc) in rec_prod:
        return 0.9, "product", "same product code %s, different package size" % ndcmod.pretty(d_ndc)[:10]
    same_strength = _norm_strength(dispense.get("strength")) == _norm_strength(extraction.get("strength")) \
        and _norm_strength(extraction.get("strength")) != ""
    if not d_ndc:
        if same_strength:
            return NO_NDC_SAME_STRENGTH, "ingredient", "record has no NDC; same ingredient and strength (heuristic %d%%)" % (NO_NDC_SAME_STRENGTH * 100)
        return OTHER_STRENGTH, "ingredient", "record has no NDC; different strength"
    if same_strength:
        return WRONG_NDC_RATE, "ingredient", "same ingredient and strength but different NDC %s (only if the record is wrong, heuristic %d%%)" % (ndcmod.pretty(d_ndc), WRONG_NDC_RATE * 100)
    return OTHER_STRENGTH, "ingredient", "same ingredient, different strength (%s)" % (dispense.get("strength") or "?")


def score_dispense(recall, extraction, dispense, patient, sdud, win=None):
    if win is None:
        win = lot_window(extraction, recall)
    lots = {l["lot"].upper() for l in extraction.get("lots", []) if l.get("lot")}
    pf, mtype, pwhy = product_factor(extraction, dispense)
    lo, hi = real_date_window(dispense.get("starttime"), patient["anchor_year"], patient["anchor_year_group"])
    res = {"dispense_id": dispense.get("id"), "match": mtype, "badges": [], "exact": False}
    scanned = (dispense.get("lot") or "").strip().upper()
    if scanned and mtype in ("ndc", "product"):
        hit = scanned in lots or extraction.get("all_lots")
        res.update(p=1.0 if hit else 0.0, exact=True,
                   factors=[{"name": "Lot (barcode)", "value": 1.0 if hit else 0.0,
                             "why": "scanned lot %s %s the recall" % (scanned, "is on" if hit else "is NOT on"),
                             "source": "GS1 DataMatrix scanned at dispensing"}])
        res["badges"] = ["NDC match", "Lot confirmed" if hit else "Lot cleared"]
        res["window"] = [lo.isoformat() if lo else "", hi.isoformat() if hi else ""]
        return res
    tf = overlap(lo, hi, win[0], win[1]) if win[0] else 0.5
    ndcs = sorted(extraction.get("ndcs") or [])
    sf, sinfo = lot_share(recall, extraction, ndcs, sdud, win)
    rf, rwhy = region_factor(extraction)
    p = pf * tf * sf * rf
    res["p"] = round(p, 6)
    res["window"] = [lo.isoformat() if lo else "", hi.isoformat() if hi else ""]
    res["factors"] = [
        {"name": "Product match", "value": pf, "why": pwhy, "source": "FDA notice NDCs vs dispensing record"},
        {"name": "Time on shelf", "value": round(tf, 4),
         "why": "real fill date is somewhere in %s..%s (MIMIC dates are shifted); %d%% of that overlaps the lot window %s..%s (%s)"
                % (res["window"][0], res["window"][1], round(tf * 100), win[0].isoformat() if win[0] else "?",
                   win[1].isoformat() if win[1] else "?", win[2]),
         "source": "MIMIC-IV anchor_year_group + FDA lot/expiry dates"},
        {"name": "Lot share", "value": round(sf, 4), "why": sinfo["basis"], "source": sinfo["source"],
         "caveat": sinfo.get("caveat", "")},
        {"name": "Region", "value": rf, "why": rwhy, "source": "FDA distribution_pattern"},
    ]
    if mtype == "ndc":
        res["badges"].append("NDC match")
    elif mtype == "product":
        res["badges"].append("Same product")
    return res


def patient_probability(items, win, step_days=7):
    """P(at least one of the patient's fills came from the recalled lot).

    MIMIC shifts all dates of one patient by the SAME unknown offset, so the
    fills are not independent in time: we average over that shared offset
    instead of multiplying per-fill time factors.
    items: [(score_dispense result, dispense)]"""
    if any(s["exact"] and s["p"] >= 1.0 for s, _ in items):
        return 1.0
    live = [(s, d) for s, d in items if not s["exact"]]       # scanned lots that are NOT on the recall drop out
    if not live:
        return 0.0
    a, b = win[0], win[1]
    fills = []
    for s, _ in live:
        other = 1.0
        for f in s.get("factors", []):
            if f["name"] != "Time on shelf":
                other *= float(f["value"])
        lo = _date(s["window"][0]) if s.get("window") else None
        hi = _date(s["window"][1]) if s.get("window") else None
        fills.append((other, lo, hi))
    if not (a and b) or any(lo is None for _, lo, _ in fills):
        q = 1.0
        for s, _ in live:
            q *= (1 - s["p"])
        return 1 - q
    span = max(1, min((hi - lo).days for _, lo, hi in fills))
    ks = range(0, span, step_days)
    total = 0.0
    for k in ks:
        q = 1.0
        for other, lo, _ in fills:
            d = lo + dt.timedelta(days=k)
            if a <= d <= b:
                q *= (1 - other)
        total += 1 - q
    return total / len(ks)


def rank_patients(recall, extraction, dispenses, patients, sdud=None, threshold=DEFAULT_THRESHOLD):
    """dispenses: candidate dispense dicts (already filtered by NDC/ingredient).
    patients: {subject_id: {...anchor fields...}}.  Returns ranked patient rows."""
    win = lot_window(extraction, recall)
    per = {}
    for d in dispenses:
        pat = patients.get(d["subject_id"])
        if not pat:
            continue
        s = score_dispense(recall, extraction, d, pat, sdud, win)
        per.setdefault(d["subject_id"], []).append((s, d))
    rows = []
    for sid, items in per.items():
        p = patient_probability(items, win)
        exact = all(s["exact"] for s, _ in items) or p >= 1.0
        best_s, best_d = max(items, key=lambda x: (x[0]["p"], x[1].get("starttime") or ""))
        badges = []
        for s, _ in items:
            for b in s["badges"]:
                if b not in badges:
                    badges.append(b)
        rows.append({
            "subject_id": sid, "p": round(p, 6), "fills": len(items), "best": best_s,
            "drug": best_d.get("drug"), "strength": best_d.get("strength"), "ndc": best_d.get("ndc"),
            "last_fill_shifted": max((d.get("starttime") or "") for _, d in items),
            "badges": badges, "exact": exact,
            "sex": patients[sid].get("gender"), "age": patients[sid].get("anchor_age"),
        })
    rows.sort(key=lambda r: (-r["p"], -r["fills"], r["subject_id"]))
    shown = [r for r in rows if r["p"] >= threshold]
    hidden = [r for r in rows if r["p"] < threshold]
    return {"window": [win[0].isoformat() if win[0] else "", win[1].isoformat() if win[1] else "", win[2]],
            "threshold": threshold, "shown": shown, "hidden": hidden,
            "total": len(rows), "expected_affected": round(sum(r["p"] for r in rows), 3)}
