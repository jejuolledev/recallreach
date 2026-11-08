"""Recall notice -> structured fields with evidence spans.

Three pieces live here:
  * notice_text(): the free text the agent reads (built only from the human
    written openFDA fields; the harmonized `openfda` block is never included,
    so the agent cannot copy FDA's NDC list).
  * reference_extract(): a deterministic rule-based extractor.  It is the
    replay-mode stand-in when no LLM key is set, and the baseline we compare
    the LLM against on the accuracy panel.
  * validate(): checks any extractor's JSON (LLM or rules) against the source
    text.  Every value must quote a verbatim evidence string; quotes that are
    not found in the notice are marked low confidence ("evidence not found").
"""
import json
import re
import datetime

from . import ndc as ndcmod

FIELDS = ["ingredient", "strength", "form", "manufacturer", "ndcs", "lots",
          "expiry_dates", "distribution", "recall_dates"]

SYSTEM_PROMPT = """You are RecallReach's recall-reading agent inside an InterSystems IRIS interoperability production.
You read one FDA drug recall notice (free text) and decide two things:
1. What exact product is recalled (fields below), quoting evidence.
2. How deep the recall goes and what the pharmacy should do:
   "hold_and_contact" (consumer-level recall: patients may hold an affected unit),
   "stock_check" (retail or wholesale level: pull the lots from the shelf, no patient contact) or "no_action".

Steps:
1. Read the notice and extract the fields.
2. Recall depth. If the notice says "consumer level", "patient level" or "user level", depth is "consumer".
   If it says "retail", "pharmacy" or "hospital level", depth is "retail"; "wholesale" or "distributor level" is "wholesale".
   Set "stated": true and quote the words as evidence. Most FDA enforcement notices do not state the depth: then set
   "stated": false, leave evidence empty and use this rule:
   - Class I: consumer.
   - Class II: consumer only if the reason names a direct risk to the patient (non-sterile, contamination, particulate
     or foreign matter, wrong drug or wrong label/barcode, super- or sub-potent dose); otherwise retail.
   - Class III: retail.
3. Call the LookupDispensed tool ONCE with the NDCs you found (comma separated, as printed) and the ingredient,
   to learn whether this pharmacy ever dispensed the recalled product. It returns counts only.
4. Decide:
   - "no_action" when the pharmacy never dispensed this ingredient;
   - "hold_and_contact" only when depth is consumer AND the pharmacy dispensed a recalled NDC
     (or the same ingredient and strength when the notice lists no NDC);
   - "stock_check" in every other case.
   Put the depth and the tool's counts in the rationale.

Rules:
- Use ONLY the notice text and the tool result. Never invent an NDC, lot or date that is not written in it.
- Every value needs "evidence": an exact, verbatim substring copied from the notice (case and spacing as written).
- "confidence" is "high" or "low". Use "low" when the text is ambiguous (several strengths, unclear lots, "all lots", etc).
- NDCs: copy them exactly as printed (with hyphens).
- Reply with ONE JSON object, no prose, no markdown fences.

JSON shape:
{"ingredient":{"value":"","evidence":"","confidence":""},
 "strength":{"value":"","evidence":"","confidence":""},
 "form":{"value":"tablet|capsule|injection|solution|suspension|inhalation|topical|patch|other","evidence":"","confidence":""},
 "manufacturer":{"value":"","evidence":"","confidence":""},
 "ndcs":[{"value":"","evidence":""}],
 "lots":[{"value":"","expiry":"YYYY-MM-DD or empty","evidence":""}],
 "all_lots":false,
 "distribution":{"nationwide":true,"states":["MA"],"evidence":"","confidence":""},
 "depth":{"value":"consumer|retail|wholesale","stated":false,"evidence":""},
 "decision":{"action":"hold_and_contact|stock_check|no_action","rationale":"one sentence"}}"""


# ------------------------------------------------------------ recall depth --
# openFDA enforcement records have no "depth" field (consumer / retail /
# wholesale level).  A few notices say it in the text; for the rest we infer
# it from the classification and the reason, with this rule (shown in the UI).
DEPTH_STATED = re.compile(r"\b(consumer|patient|user|retail|pharmacy|hospital|wholesale|wholesaler|distributor)[- ]level\b", re.I)
DEPTH_WORD = {"consumer": "consumer", "patient": "consumer", "user": "consumer", "retail": "retail",
              "pharmacy": "retail", "hospital": "retail", "wholesale": "wholesale", "wholesaler": "wholesale",
              "distributor": "wholesale"}
PATIENT_RISK = re.compile(
    r"steril|non-?sterile|contamina|microb|bacteri|fung|mold|yeast|burkholderia|endotoxin|particulate|foreign"
    r"|glass|metal (?:particle|fragment|shaving)|mislabel|label mix|mix-?up|wrong (?:drug|product|tablet|capsule|strength|label|barcode)"
    r"|incorrect (?:barcode|label|strength|drug|product)|super-?potent|sub-?potent|overdos|cross-contamina", re.I)


def recall_depth(recall):
    """{"value": consumer|retail|wholesale, "stated": bool, "evidence": str, "basis": str}"""
    text = notice_text(recall)
    m = DEPTH_STATED.search(text)
    if m:
        v = DEPTH_WORD[m.group(1).lower()]
        return {"value": v, "stated": True, "evidence": m.group(0),
                "basis": "the notice says \"%s\"" % m.group(0), "short": "stated in the notice"}
    cls = recall.get("classification", "")
    reason = recall.get("reason_for_recall", "") or ""
    if cls == "Class I":
        return {"value": "consumer", "stated": False, "evidence": "",
                "basis": "not stated in the notice, so inferred: Class I recalls usually go to the consumer level",
                "short": "inferred from Class I"}
    if cls == "Class II":
        r = PATIENT_RISK.search(reason)
        if r:
            word = re.search(r"[\w-]*%s[\w-]*" % re.escape(r.group(0)), reason, re.I)
            word = word.group(0) if word else r.group(0)
            return {"value": "consumer", "stated": False, "evidence": "",
                    "basis": "not stated in the notice, so inferred: Class II and the reason names a direct patient risk (\"%s\")" % word,
                    "short": "inferred from Class II + patient-risk reason"}
        return {"value": "retail", "stated": False, "evidence": "",
                "basis": "not stated in the notice, so inferred: Class II and the reason is a quality or process problem, not a direct patient risk",
                "short": "inferred from Class II + quality-only reason"}
    return {"value": "retail", "stated": False, "evidence": "",
            "basis": "not stated in the notice, so inferred: %s recalls usually stop at the retail level" % (cls or "unclassified"),
            "short": "inferred from %s" % (cls or "no classification")}


def plural(n, word, many=None):
    return "%d %s" % (n, word if n == 1 else (many or word + "s"))


def notice_text(recall):
    """The text the agent reads. Built from human-written openFDA fields only."""
    parts = [
        ("Recall number", recall.get("recall_number", "")),
        ("Classification", recall.get("classification", "")),
        ("Recalling firm", recall.get("recalling_firm", "")),
        ("Product", recall.get("product_description", "")),
        ("Reason", recall.get("reason_for_recall", "")),
        ("Lots / codes", recall.get("code_info", "")),
        ("Quantity", recall.get("product_quantity", "")),
        ("Distribution", recall.get("distribution_pattern", "")),
        ("Recall initiated", fmt_date(recall.get("recall_initiation_date", ""))),
    ]
    return "\n".join("%s: %s" % (k, (v or "").strip()) for k, v in parts)


def user_prompt(recall):
    return "Read this FDA recall notice and reply with the JSON object.\n\n" + notice_text(recall)


def fmt_date(yyyymmdd):
    s = (yyyymmdd or "").strip()
    if re.fullmatch(r"\d{8}", s):
        return "%s-%s-%s" % (s[:4], s[4:6], s[6:])
    return s


# ---------------------------------------------------------------- rules ----
FORM_WORDS = [
    ("tablet", r"\btablets?\b|\bcaplets?\b"),
    ("capsule", r"\bcapsules?\b"),
    ("inhalation", r"\binhal\w*\b|\baerosol\b|\bnebuli\w*\b"),
    ("injection", r"\binjection\b|\binjectable\b|\bfor injection\b|\bvials?\b|\bsyringes?\b"),
    ("patch", r"\bpatch(es)?\b|\btransdermal\b"),
    ("suspension", r"\bsuspension\b"),
    ("solution", r"\bsolution\b|\boral liquid\b|\bsyrup\b|\belixir\b"),
    ("topical", r"\bcream\b|\bointment\b|\bgel\b|\blotion\b"),
]
STRENGTH = re.compile(
    r"(?<![\w.])(\d+(?:[.,]\d+)?\s?(?:mg|mcg|µg|g|mEq|units?|USP units|IU|%|mL)"
    r"(?:\s?(?:/|per)\s?\d*(?:\.\d+)?\s?(?:mL|L|actuation|tablet|capsule|g))?)",
    re.I)
MFR = re.compile(r"(?:Manufactured\s+(?:by|for)|Mfd\.?\s*(?:by|for)|MFG\.?\s*(?:by)?|Made\s+by|Distributed\s+by|Mfr)\s*:?\s*([A-Z][^,;:.\n]{2,60})", re.I)
LOT_LINE = re.compile(r"\b(?:lot|lots|batch)\s*(?:#|no\.?|number|numbers|nos\.?)?\s*:?\s*", re.I)
LOT_TOKEN = re.compile(r"\b([A-Z0-9]*\d[A-Z0-9-]{2,}[A-Z0-9])\b")
EXP = re.compile(r"\b(?:exp(?:iry|iration)?\.?(?:\s*date)?|expires?)\s*:?\s*(\d{1,2}/\d{1,2}/\d{2,4}|\d{1,2}/\d{2,4}|\d{4}-\d{2}-\d{2}|[A-Z][a-z]{2,8}\.?\s*\d{1,2},?\s*\d{4}|[A-Z][a-z]{2}\s?\d{4})", re.I)
US_STATES = {
    "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California", "CO": "Colorado",
    "CT": "Connecticut", "DE": "Delaware", "FL": "Florida", "GA": "Georgia", "HI": "Hawaii", "ID": "Idaho",
    "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana",
    "ME": "Maine", "MD": "Maryland", "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota",
    "MS": "Mississippi", "MO": "Missouri", "MT": "Montana", "NE": "Nebraska", "NV": "Nevada",
    "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York", "NC": "North Carolina",
    "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania",
    "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas",
    "UT": "Utah", "VT": "Vermont", "VA": "Virginia", "WA": "Washington", "WV": "West Virginia",
    "WI": "Wisconsin", "WY": "Wyoming", "DC": "District of Columbia", "PR": "Puerto Rico",
}
NATIONWIDE = re.compile(r"\bnation\s?wide\b|\bthroughout the (?:US|U\.S\.|United States)\b|\ball (?:50 )?states\b|\bUS\b|\bU\.S\.|\bUSA\b|\bUnited States\b", re.I)
MONTHS = {m: i + 1 for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"])}


def _line_span(text, label):
    i = text.find(label + ": ")
    if i < 0:
        return 0, 0
    s = i + len(label) + 2
    e = text.find("\n", s)
    return s, (len(text) if e < 0 else e)


def parse_expiry(s):
    s = (s or "").strip().rstrip(".,;")
    m = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})", s)
    if m:
        return s
    m = re.fullmatch(r"(\d{1,2})/(\d{1,2})/(\d{2,4})", s)
    if m:
        mm, dd, yy = int(m.group(1)), int(m.group(2)), int(m.group(3))
        yy = yy + 2000 if yy < 100 else yy
        try:
            return datetime.date(yy, mm, dd).isoformat()
        except ValueError:
            return ""
    m = re.fullmatch(r"(\d{1,2})/(\d{2,4})", s)
    if m:
        mm, yy = int(m.group(1)), int(m.group(2))
        yy = yy + 2000 if yy < 100 else yy
        if 1 <= mm <= 12:
            nxt = datetime.date(yy + mm // 12, mm % 12 + 1, 1)
            return (nxt - datetime.timedelta(days=1)).isoformat()
        return ""
    m = re.fullmatch(r"([A-Za-z]{3})[a-z]*\.?\s*(\d{1,2})?,?\s*(\d{4})", s)
    if m and m.group(1).lower() in MONTHS:
        mm, yy = MONTHS[m.group(1).lower()], int(m.group(3))
        if m.group(2):
            try:
                return datetime.date(yy, mm, int(m.group(2))).isoformat()
            except ValueError:
                return ""
        nxt = datetime.date(yy + mm // 12, mm % 12 + 1, 1)
        return (nxt - datetime.timedelta(days=1)).isoformat()
    return ""


def reference_extract(recall):
    """Deterministic extractor. Returns the same JSON shape the LLM must produce."""
    text = notice_text(recall)
    ps, pe = _line_span(text, "Product")
    product = text[ps:pe]
    out = {}

    # ingredient: words before the first form word / strength / comma
    stop = re.search(r",|\(|\b(tablets?|capsules?|injection|oral|for injection|solution|suspension|cream|ointment|"
                     r"inhalation|extended|delayed|chewable|USP|\d)", product, re.I)
    ing = product[:stop.start()].strip(" ,-") if stop else product[:40]
    brand = re.match(r"\s*([A-Z][A-Za-z0-9-]+(?:\s+[A-Za-z0-9-]+){0,2})\s*\(([^)]+)\)", product)
    if brand and not re.search(r"\d|NDC|count", brand.group(2), re.I):
        # "Synthroid (levothyroxine sodium) ..." / "Ventolin HFA (albuterol sulfate) ..." -> generic inside parentheses
        ing = brand.group(2).strip()
    ing_conf = "high" if 2 <= len(ing) <= 60 and not re.search(r"\d", ing) else "low"
    out["ingredient"] = {"value": ing, "evidence": ing, "confidence": ing_conf}

    strengths = [m for m in STRENGTH.finditer(product)]
    if strengths:
        uniq = []
        for m in strengths:
            v = re.sub(r"\s+", " ", m.group(1)).strip()
            if v.lower() not in [u.lower() for u in uniq]:
                uniq.append(v)
        out["strength"] = {"value": uniq[0], "evidence": strengths[0].group(1),
                           "confidence": "high" if len(uniq) == 1 else "low"}
    else:
        out["strength"] = {"value": "", "evidence": "", "confidence": "low"}

    form, fev = "other", ""
    for name, rx in FORM_WORDS:
        m = re.search(rx, product, re.I)
        if m:
            form, fev = name, m.group(0)
            break
    out["form"] = {"value": form, "evidence": fev, "confidence": "high" if fev else "low"}

    m = MFR.search(product)
    if m:
        out["manufacturer"] = {"value": m.group(1).strip(), "evidence": m.group(1).strip(), "confidence": "high"}
    else:
        firm = recall.get("recalling_firm", "")
        out["manufacturer"] = {"value": firm, "evidence": firm, "confidence": "low"}

    out["ndcs"] = []
    seen = set()
    for n11, s, e, raw in ndcmod.find_in_text(text):
        if n11 not in seen:
            seen.add(n11)
            out["ndcs"].append({"value": raw, "evidence": raw})

    cs, ce = _line_span(text, "Lots / codes")
    code = text[cs:ce]
    lots = []
    all_lots = bool(re.search(r"\ball lots\b|\ball (?:unexpired|in-date)\b", code + " " + product, re.I))
    # pair each lot token with the next expiry that follows it
    exps = [(m.start(), parse_expiry(m.group(1)), m.group(0)) for m in EXP.finditer(code)]
    if LOT_LINE.search(code) or exps:
        ndc_spans = [(s - cs, e - cs) for _, s, e, _ in ndcmod.find_in_text(text) if cs <= s < ce]
        for m in LOT_TOKEN.finditer(code):
            tok = m.group(1)
            if any(s <= m.start() < e for s, e in ndc_spans):
                continue
            if any(m.start() >= p and m.start() < p + len(raw) for p, _, raw in exps):
                continue  # part of an expiry date
            if re.fullmatch(r"\d{1,2}/\d{2,4}", tok) or re.fullmatch(r"(19|20)\d{2}", tok):
                continue
            nxt = [x for x in exps if x[0] > m.start()]
            lots.append({"value": tok, "expiry": nxt[0][1] if nxt else "", "evidence": tok})
    out["lots"] = lots
    out["all_lots"] = all_lots

    ds, de = _line_span(text, "Distribution")
    dist = text[ds:de]
    states = sorted({ab for ab, name in US_STATES.items()
                     if re.search(r"\b%s\b" % ab, dist) or re.search(r"\b%s\b" % re.escape(name), dist, re.I)})
    nationwide = bool(NATIONWIDE.search(dist))
    out["distribution"] = {"nationwide": nationwide, "states": states, "evidence": dist[:200],
                           "confidence": "high" if (nationwide or states) else "low"}

    dep = recall_depth(recall)
    out["depth"] = {"value": dep["value"], "stated": dep["stated"], "evidence": dep["evidence"]}
    if dep["value"] == "consumer":
        action, why = "hold_and_contact", "Consumer-level recall (%s): patients may still hold affected units." % dep["short"]
    else:
        action, why = "stock_check", "%s-level recall (%s): pull the lots from the shelf, no patient contact." % (dep["value"].capitalize(), dep["short"])
    out["decision"] = {"action": action, "rationale": why}
    return out


def reference_decide(recall, extraction, tool_result):
    """Rule-based twin of the agent's decision step, given the LookupDispensed result."""
    ndc_fills = sum(int(x.get("fills") or 0) for x in (tool_result.get("ndcs") or []))
    ndc_pats = sum(int(x.get("patients") or 0) for x in (tool_result.get("ndcs") or []))
    ing_fills = int(tool_result.get("ingredient_fills") or 0)
    dep = recall_depth(recall)
    counts = "LookupDispensed: %s of the recalled NDCs for %s (%s of the ingredient)" % (
        plural(ndc_fills, "fill"), plural(ndc_pats, "patient"), plural(ing_fills, "fill"))
    if ndc_fills == 0 and ing_fills == 0:
        return {"action": "no_action", "rationale": "LookupDispensed: this pharmacy never dispensed %s (0 fills)." % (extraction.get("ingredient", {}).get("value") or "this product")}
    if dep["value"] == "consumer" and (ndc_fills > 0 or not extraction.get("ndcs")):
        return {"action": "hold_and_contact", "rationale": "Consumer-level recall (%s). %s." % (dep["short"], counts)}
    if dep["value"] == "consumer":
        return {"action": "stock_check", "rationale": "Consumer-level recall, but the recalled NDCs were never dispensed here. %s: check the shelf, no patient calls." % counts}
    return {"action": "stock_check", "rationale": "%s-level recall (%s). %s. Pull the lots from the shelf; no patient calls." % (dep["value"].capitalize(), dep["short"], counts)}


# ------------------------------------------------------------ validation --
def _find_span(text, ev, start=0):
    if not ev:
        return -1, -1
    i = text.find(ev, start)
    if i < 0:
        i = text.lower().find(ev.lower(), start)
    if i < 0:
        # tolerate whitespace differences
        pat = r"\s+".join(re.escape(w) for w in ev.split())
        m = re.search(pat, text[start:], re.I) if pat else None
        if not m:
            return -1, -1
        return start + m.start(), start + m.end()
    return i, i + len(ev)


def parse_json_reply(content):
    """LLM replies sometimes wrap JSON in fences or prose; take the outer object."""
    s = (content or "").strip()
    s = re.sub(r"^```(?:json)?\s*|\s*```$", "", s)
    i, j = s.find("{"), s.rfind("}")
    if i < 0 or j <= i:
        raise ValueError("no JSON object in agent reply")
    return json.loads(s[i:j + 1])


def validate(recall, data):
    """Attach character spans, flag hallucinated evidence, normalise NDCs.

    Returns a dict with 'fields' (list for the UI) and the cleaned values.
    """
    text = notice_text(recall)
    fields = []

    def add(key, label, value, ev, conf, extra=None):
        s, e = _find_span(text, ev)
        note = ""
        if ev and s < 0:
            conf, note = "low", "evidence not found in notice"
        if not value:
            conf = "low"
            note = note or "not stated"
        f = {"key": key, "label": label, "value": value, "evidence": ev, "start": s, "end": e,
             "confidence": conf or "low", "note": note}
        if extra:
            f.update(extra)
        fields.append(f)
        return f

    def one(key, label):
        v = data.get(key) or {}
        if isinstance(v, str):
            v = {"value": v, "evidence": v, "confidence": "low"}
        return add(key, label, (v.get("value") or "").strip(), (v.get("evidence") or "").strip(), v.get("confidence"))

    one("ingredient", "Ingredient")
    one("strength", "Strength")
    one("form", "Dosage form")
    one("manufacturer", "Manufacturer / labeler")

    ndcs = []
    for item in data.get("ndcs") or []:
        raw = (item.get("value") if isinstance(item, dict) else str(item)) or ""
        ev = (item.get("evidence") if isinstance(item, dict) else raw) or raw
        n11 = ndcmod.to_11(raw)
        f = add("ndc", "NDC", raw, ev, "high" if n11 else "low",
                {"ndc11": n11 or ""})
        if not n11:
            f["note"] = f["note"] or "not a valid NDC"
        if n11 and f["start"] >= 0:
            ndcs.append(n11)
    if not data.get("ndcs"):
        add("ndc", "NDC", "", "", "low")

    lots = []
    for item in data.get("lots") or []:
        raw = (item.get("value") or "").strip()
        exp = (item.get("expiry") or "").strip()
        f = add("lot", "Lot", raw, (item.get("evidence") or raw).strip(), "high", {"expiry": exp})
        if raw and f["start"] >= 0:
            lots.append({"lot": raw, "expiry": exp})
    if not data.get("lots"):
        add("lot", "Lot", "all lots" if data.get("all_lots") else "", "", "low")

    dist = data.get("distribution") or {}
    states = [s for s in (dist.get("states") or []) if s in US_STATES]
    dv = "Nationwide" if dist.get("nationwide") else (", ".join(states) if states else "")
    add("distribution", "Distribution", dv, (dist.get("evidence") or "").strip(), dist.get("confidence"))

    # recall depth: trust the agent only when it quotes the notice; else the documented rule
    rule = recall_depth(recall)
    dd = data.get("depth") if isinstance(data.get("depth"), dict) else {}
    depth = dict(rule)
    if dd.get("stated") and dd.get("value") in ("consumer", "retail", "wholesale") and dd.get("evidence"):
        s_, e_ = _find_span(text, dd["evidence"])
        if s_ >= 0:
            depth = {"value": dd["value"], "stated": True, "evidence": dd["evidence"],
                     "basis": "the notice says \"%s\"" % dd["evidence"], "short": "stated in the notice"}
    add("depth", "Recall depth", depth["value"].capitalize() + " level" + ("" if depth["stated"] else " (inferred)"),
        depth.get("evidence", ""), "high" if depth["stated"] else "low", {"basis": depth["basis"]})
    if not depth["stated"]:
        fields[-1]["note"] = depth["basis"]

    dec = data.get("decision") or {}
    action = dec.get("action") if dec.get("action") in ("hold_and_contact", "stock_check", "no_action") else "stock_check"
    rationale = (dec.get("rationale") or "")[:500]
    if action == "hold_and_contact" and depth["value"] != "consumer":
        # guard rail: patients are contacted only for consumer-level recalls
        action = "stock_check"
        rationale = ("%s-level recall: changed to a shelf check (patients are contacted only for consumer-level recalls). " % depth["value"].capitalize() + rationale)[:500]
    return {
        "fields": fields,
        "ingredient": (data.get("ingredient") or {}).get("value", "") if isinstance(data.get("ingredient"), dict) else str(data.get("ingredient") or ""),
        "strength": (data.get("strength") or {}).get("value", "") if isinstance(data.get("strength"), dict) else "",
        "form": (data.get("form") or {}).get("value", "") if isinstance(data.get("form"), dict) else "",
        "ndcs": sorted(set(ndcs)),
        "lots": lots,
        "all_lots": bool(data.get("all_lots")),
        "nationwide": bool(dist.get("nationwide")),
        "states": states,
        "action": action,
        "rationale": rationale,
        "depth": depth,
        "low_confidence": sum(1 for f in fields if f["confidence"] == "low" and f["key"] != "depth"),
        "text": text,
    }
