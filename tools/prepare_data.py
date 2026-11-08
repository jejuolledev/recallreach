"""Build the small data files shipped in data/ from the original downloads.

Inputs (not shipped):  MIMIC-IV Clinical Database Demo v2.2 CSVs, openFDA
drug-enforcement bulk JSON.  Run once:

    python3 -I tools/prepare_data.py <dir with mimic/ and openfda/> data/
"""
import collections
import csv
import gzip
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "python"))
from recallreach_core import ndc as ndcmod  # noqa: E402

# first recall of "Simulate new FDA recall": Class I mix-up of a daily blood-pressure tablet, consumer level,
# so it goes the patient-contact way
DEMO_RECALL = "D-1206-2018"
# the barcode the demo pharmacist scanned when filling patient 10012853 (recalled lot PW05264)
DEMO_SAMPLE = {"ndc11": "16729018201", "lot": "PW05264", "expiry": "2019-11-30", "dispense_id": 7171, "subject_id": "10012853"}
# already processed when the demo starts (shown in the inbox as history)
HISTORY = ["D-0668-2016", "D-1467-2016", "D-0013-2018", "D-1226-2015", "D-1223-2015", "D-0793-2017", "D-0464-2017"]
# delivered one by one by "Simulate new FDA recall" (first = the video recall)
QUEUE = [DEMO_RECALL, "D-1695-2012", "D-0010-2016", "D-0123-2018", "D-1208-2015", "D-0648-2016"]


def rd(base, name):
    with gzip.open(os.path.join(base, "mimic", name + ".csv.gz"), "rt") as f:
        return list(csv.DictReader(f))


def main(src, out):
    os.makedirs(out, exist_ok=True)
    pats = rd(src, "patients")
    adm = {a["hadm_id"]: a for a in rd(src, "admissions")}
    rx = rd(src, "prescriptions")
    patients = [{"subject_id": p["subject_id"], "gender": p["gender"], "anchor_age": int(p["anchor_age"]),
                 "anchor_year": int(p["anchor_year"]), "anchor_year_group": p["anchor_year_group"].replace(" ", "")}
                for p in pats]
    disp = []
    for i, r in enumerate(rx):
        if not r["drug"]:
            continue
        n = r["ndc"] if r["ndc"] and len(r["ndc"]) == 11 and r["ndc"] != "00000000000" else ""
        a = adm.get(r["hadm_id"], {})
        disp.append({"id": i + 1, "subject_id": r["subject_id"], "hadm_id": r["hadm_id"],
                     "starttime": r["starttime"], "drug": r["drug"], "ndc": n,
                     "strength": r["prod_strength"], "form": r["form_rx"], "route": r["route"],
                     "dose": (r["dose_val_rx"] + " " + r["dose_unit_rx"]).strip(),
                     "discharge": a.get("discharge_location", "")})
    ndcs = {d["ndc"] for d in disp if d["ndc"]}

    with open(os.path.join(src, "openfda", "drug-enforcement-0001-of-0001.json")) as f:
        allr = json.load(f)["results"]
    keep, hits = {}, []
    for rc in allr:
        nd = {ndcmod.to_11(k) for k in (rc.get("openfda") or {}).get("package_ndc", [])} - {None}
        txt = {n for n, _, _, _ in ndcmod.find_in_text(rc.get("product_description", ""))}
        if (nd | txt) & ndcs:
            keep[rc["recall_number"]] = rc
            hits.append(rc["recall_number"])
    # accuracy benchmark: recalls that carry FDA's harmonized NDC list
    rnd = random.Random(20261108)
    with_ndc = [rc for rc in allr if (rc.get("openfda") or {}).get("package_ndc")]
    bench = rnd.sample(with_ndc, 300)
    for rc in bench:
        keep[rc["recall_number"]] = rc
    slim = []
    fields = ["recall_number", "classification", "status", "recalling_firm", "city", "state", "country",
              "product_description", "reason_for_recall", "code_info", "product_quantity",
              "distribution_pattern", "recall_initiation_date", "report_date", "center_classification_date",
              "termination_date", "voluntary_mandated", "event_id"]
    for rc in keep.values():
        s = {k: rc.get(k, "") for k in fields}
        of = rc.get("openfda") or {}
        s["openfda"] = {k: of.get(k, []) for k in ("package_ndc", "product_ndc", "generic_name", "brand_name",
                                                   "manufacturer_name", "substance_name", "route")}
        slim.append(s)
    slim.sort(key=lambda s: s["recall_number"])
    meta = {"demo_recall": DEMO_RECALL, "demo_sample": DEMO_SAMPLE, "history": HISTORY, "queue": QUEUE, "featured": HISTORY + QUEUE, "mimic_hits": sorted(hits), "benchmark": sorted(r["recall_number"] for r in bench),
            "openfda_last_updated": "2026-11-03", "openfda_total": len(allr)}
    for name, obj in (("patients.json", patients), ("dispenses.json", disp), ("recalls.json", slim), ("meta.json", meta)):
        with open(os.path.join(out, name), "w") as f:
            json.dump(obj, f, separators=(",", ":"))
    print("patients", len(patients), "dispenses", len(disp), "recalls", len(slim), "hits", len(hits), "bench", len(bench))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
