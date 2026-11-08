"""Cache CMS Medicaid State Drug Utilization Data (national rows, state=XX)
for the NDCs of the featured recalls, so the app needs no internet at runtime.

    python3 -I tools/fetch_sdud.py data/

Source: https://data.medicaid.gov  (datasets "State Drug Utilization Data <year>")
Value stored per NDC and quarter: units_reimbursed summed over FFSU + MCOU rows;
null when CMS suppressed every row for that quarter (fewer than 11 claims).
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "python"))
from recallreach_core import extract, probability  # noqa: E402

CATALOG = "https://data.medicaid.gov/api/1/metastore/schemas/dataset/items?show-reference-ids=false"


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "RecallReach/1.0 (contest demo)"})
    with urllib.request.urlopen(req, timeout=90) as r:
        return json.loads(r.read().decode())


def main(out):
    meta = json.load(open(os.path.join(out, "meta.json")))
    recalls = {r["recall_number"]: r for r in json.load(open(os.path.join(out, "recalls.json")))}
    ids = {}
    for d in get(CATALOG):
        t = d.get("title", "")
        if t.startswith("State Drug Utilization Data ") and t[-4:].isdigit():
            ids[int(t[-4:])] = d["identifier"]
    cache_path = os.path.join(out, "sdud_cache.json")
    cache = json.load(open(cache_path)) if os.path.exists(cache_path) else {"_source": {}, "ndc": {}}
    for rn in meta["featured"]:
        rc = recalls[rn]
        v = extract.validate(rc, extract.reference_extract(rc))
        a, b, _ = probability.lot_window(v, rc)
        if not a:
            continue
        for year in range(a.year, b.year + 1):
            if year not in ids:
                continue
            for n in v["ndcs"]:
                key = "%s:%d" % (n, year)
                if key in cache["_source"]:
                    continue
                q = urllib.parse.urlencode({
                    "conditions[0][property]": "ndc", "conditions[0][value]": n,
                    "conditions[1][property]": "state", "conditions[1][value]": "XX", "limit": "50"})
                url = "https://data.medicaid.gov/api/1/datastore/query/%s/0?%s" % (ids[year], q)
                try:
                    res = get(url).get("results", [])
                except Exception as e:  # keep going, record the failure
                    print("fail", key, e)
                    continue
                per = cache["ndc"].setdefault(n, {})
                for row in res:
                    qk = "%sQ%s" % (row["year"], row["quarter"])
                    u = row.get("units_reimbursed")
                    if u is None:
                        per.setdefault(qk, None)
                    else:
                        per[qk] = (per.get(qk) or 0) + float(u)
                cache["_source"][key] = {"dataset": ids[year], "rows": len(res), "fetched": time.strftime("%Y-%m-%d")}
                print(rn, key, len(res))
                time.sleep(0.3)
    json.dump(cache, open(cache_path, "w"), indent=0, sort_keys=True)


if __name__ == "__main__":
    main(sys.argv[1])
