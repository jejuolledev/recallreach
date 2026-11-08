"""Accuracy panel: hide FDA's harmonized NDC list, let an extractor read the
free text, compare.  Works for the rule-based extractor and for recorded LLM
outputs alike."""
import re
from . import extract, ndc as ndcmod


def fda_ndcs(recall):
    of = recall.get("openfda") or {}
    out = set()
    for k in of.get("package_ndc") or []:
        n = ndcmod.to_11(k)
        if n:
            out.add(n)
    return out


def fda_products(recall):
    of = recall.get("openfda") or {}
    out = set()
    for k in of.get("product_ndc") or []:
        a = k.split("-")
        if len(a) == 2:
            n = ndcmod.to_11(k + "-00")
            if n:
                out.add(n[:9])
    return out


def score_one(recall, validated):
    truth = fda_ndcs(recall)
    truth_prod = fda_products(recall) | {n[:9] for n in truth}
    got = set(validated["ndcs"])
    hit_pkg = bool(got & truth)
    hit_prod = bool({n[:9] for n in got} & truth_prod)
    wrong = sorted(n for n in got if n[:9] not in truth_prod)
    of = recall.get("openfda") or {}
    names = " ".join((of.get("generic_name") or []) + (of.get("substance_name") or [])).lower()
    ing = (validated.get("ingredient") or "").lower().strip()
    ing_hit = bool(ing) and any(w in names for w in re.split(r"[^a-z0-9]+", ing) if len(w) > 3)
    return {
        "recall_number": recall["recall_number"],
        "fda_ndcs": sorted(truth), "extracted": sorted(got),
        "package_hit": hit_pkg, "product_hit": hit_prod, "extra_wrong": wrong,
        "found_any": bool(got), "ingredient_hit": ing_hit, "ingredient": validated.get("ingredient", ""),
        "fda_generic": (of.get("generic_name") or [""])[0],
    }


def summarize(rows, label):
    n = len(rows) or 1
    def pct(k):
        return round(100.0 * sum(1 for r in rows if r[k]) / n, 1)
    wrong = [r for r in rows if not r["product_hit"] or r["extra_wrong"] or not r["ingredient_hit"]]
    return {
        "extractor": label, "n": len(rows),
        "ndc_found_pct": pct("found_any"),
        "ndc_product_hit_pct": pct("product_hit"),
        "ndc_package_hit_pct": pct("package_hit"),
        "ingredient_hit_pct": pct("ingredient_hit"),
        "with_wrong_ndc": sum(1 for r in rows if r["extra_wrong"]),
        "wrong_examples": wrong[:25],
    }


def run_reference(recalls):
    rows = []
    for r in recalls:
        v = extract.validate(r, extract.reference_extract(r))
        rows.append(score_one(r, v))
    return summarize(rows, "rule-based reference extractor")
