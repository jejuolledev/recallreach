/// Embedded Python bridge to the recallreach_core package
/// (/usr/irissys/mgr/python/recallreach_core). JSON strings in, JSON strings out.
Class RecallReach.Core.Py
{

ClassMethod SystemPrompt() As %String [ Language = python ]
{
    from recallreach_core import extract
    return extract.SYSTEM_PROMPT
}

ClassMethod UserPrompt(recallJson As %String) As %String [ Language = python ]
{
    import json
    from recallreach_core import extract
    return extract.user_prompt(json.loads(recallJson))
}

ClassMethod NoticeText(recallJson As %String) As %String [ Language = python ]
{
    import json
    from recallreach_core import extract
    return extract.notice_text(json.loads(recallJson))
}

/// Deterministic reference extractor output (same JSON shape the LLM must return).
ClassMethod ReferenceReply(recallJson As %String) As %String [ Language = python ]
{
    import json
    from recallreach_core import extract
    return json.dumps(extract.reference_extract(json.loads(recallJson)))
}

/// Parse + validate an agent reply against the notice text. Returns JSON or {"error":...}.
ClassMethod Validate(recallJson As %String, content As %String) As %String [ Language = python ]
{
    import json
    from recallreach_core import extract
    rec = json.loads(recallJson)
    try:
        data = extract.parse_json_reply(content)
    except Exception as e:
        return json.dumps({"error": "agent reply is not valid JSON: %s" % e})
    v = extract.validate(rec, data)
    v["evidence_not_found"] = sum(1 for f in v["fields"] if f["note"] == "evidence not found in notice")
    return json.dumps(v)
}

ClassMethod StripFences(content As %String) As %String [ Language = python ]
{
    import json
    from recallreach_core import extract
    return json.dumps(extract.parse_json_reply(content))
}

ClassMethod ParseGS1(raw As %String) As %String [ Language = python ]
{
    import json
    from recallreach_core import gs1
    try:
        return json.dumps(gs1.parse(raw))
    except Exception as e:
        return json.dumps({"error": str(e)})
}

ClassMethod BuildGS1(ndc11 As %String, lot As %String, expiry As %String, serial As %String) As %String [ Language = python ]
{
    from recallreach_core import gs1
    return gs1.build(ndc11, lot, expiry, serial)
}

/// Find candidate dispenses (exact NDC via SQL index + ingredient via IRIS
/// Vector Search) and rank patients by estimated probability.
ClassMethod Match(recallJson As %String, validatedJson As %String, sdudPath As %String, threshold As %Double = 0.05) As %String [ Language = python ]
{
    import json, os, iris
    from recallreach_core import probability, vectors, ndc as ndcmod
    rec = json.loads(recallJson)
    v = json.loads(validatedJson)
    sdud = {}
    if sdudPath and os.path.exists(sdudPath):
        with open(sdudPath) as f:
            sdud = json.load(f).get("ndc", {})
    cols = "DispenseId,SubjectId,StartTime,Drug,NDC,Strength,Form,Route,Lot,LotExpiry,HoldNextFill"
    def rows(sql, *args):
        out = []
        for r in iris.sql.exec(sql, *args):
            out.append({"id": r[0], "subject_id": r[1], "starttime": r[2], "drug": r[3], "ndc": r[4] or "",
                        "strength": r[5] or "", "form": r[6] or "", "route": r[7] or "", "lot": r[8] or "",
                        "lot_expiry": r[9] or "", "hold": bool(r[10])})
        return out
    cands = {}
    for n in v.get("ndcs", []):
        for d in rows("SELECT " + cols + " FROM RecallReach_Data.Dispense WHERE NDC = ?", n):
            cands[d["id"]] = d
    # same product code, other package sizes
    for pc in sorted({n[:9] for n in v.get("ndcs", [])}):
        for d in rows("SELECT " + cols + " FROM RecallReach_Data.Dispense WHERE NDC %STARTSWITH ?", pc):
            cands[d["id"]] = d
    vec_hits = []
    ing = vectors.normalize(v.get("ingredient", ""))
    if ing:
        q = vectors.to_iris(vectors.embed(ing))
        first = ing.split()[0][:5]
        sql = ("SELECT TOP 12 Name, Norm, VECTOR_COSINE(Vec, TO_VECTOR(?, DOUBLE, 128)) AS score "
               "FROM RecallReach_Data.DrugName ORDER BY score DESC")
        for r in iris.sql.exec(sql, q):
            name, norm, score = r[0], r[1] or "", float(r[2] or 0)
            ok = score >= 0.55 and norm[:5] == first
            vec_hits.append({"name": name, "score": round(score, 3), "used": ok})
            if ok:
                for d in rows("SELECT " + cols + " FROM RecallReach_Data.Dispense WHERE Drug = ?", name):
                    cands.setdefault(d["id"], d)
    pats = {}
    for r in iris.sql.exec("SELECT SubjectId, Gender, AnchorAge, AnchorYear, AnchorYearGroup FROM RecallReach_Data.Patient"):
        pats[r[0]] = {"gender": r[1], "anchor_age": r[2], "anchor_year": r[3], "anchor_year_group": r[4]}
    res = probability.rank_patients(rec, v, list(cands.values()), pats, sdud, float(threshold))
    res["vector_search"] = vec_hits
    res["candidates"] = len(cands)
    for row in res["shown"] + res["hidden"]:
        row["ndc_pretty"] = ndcmod.pretty(row.get("ndc") or "")
    return json.dumps(res)
}

/// Accuracy panel: rule-based extractor on the benchmark + recorded LLM replies when present.
ClassMethod Accuracy(dataDir As %String, recordDir As %String) As %String [ Language = python ]
{
    import json, os
    from recallreach_core import accuracy, extract
    meta = json.load(open(os.path.join(dataDir, "meta.json")))
    recs = {r["recall_number"]: r for r in json.load(open(os.path.join(dataDir, "recalls.json")))}
    bench = [recs[k] for k in meta["benchmark"] if k in recs]
    out = {"benchmark_size": len(bench), "reference": accuracy.run_reference(bench), "llm": None}
    rows = []
    if recordDir and os.path.isdir(recordDir):
        for r in bench:
            p = os.path.join(recordDir, r["recall_number"] + ".json")
            if os.path.exists(p):
                rec = json.load(open(p))
                try:
                    v = extract.validate(r, extract.parse_json_reply(rec.get("content", "")))
                    rows.append(accuracy.score_one(r, v))
                except Exception:
                    rows.append({"recall_number": r["recall_number"], "fda_ndcs": sorted(accuracy.fda_ndcs(r)),
                                 "extracted": [], "package_hit": False, "product_hit": False, "extra_wrong": [],
                                 "found_any": False, "ingredient_hit": False, "ingredient": "(invalid JSON)",
                                 "fda_generic": ""})
    if rows:
        out["llm"] = accuracy.summarize(rows, "AI Hub agent (recorded live replies)")
    return json.dumps(out)
}

/// Load the shipped data files into IRIS tables (idempotent).
ClassMethod LoadData(dataDir As %String) As %String [ Language = python ]
{
    import json, os, iris
    from recallreach_core import vectors
    iris.sql.exec("DELETE FROM RecallReach_Data.Patient")
    iris.sql.exec("DELETE FROM RecallReach_Data.Dispense")
    iris.sql.exec("DELETE FROM RecallReach_Data.DrugName")
    pats = json.load(open(os.path.join(dataDir, "patients.json")))
    for p in pats:
        iris.sql.exec("INSERT INTO RecallReach_Data.Patient (SubjectId, Gender, AnchorAge, AnchorYear, AnchorYearGroup) VALUES (?,?,?,?,?)",
                      p["subject_id"], p["gender"], p["anchor_age"], p["anchor_year"], p["anchor_year_group"])
    disp = json.load(open(os.path.join(dataDir, "dispenses.json")))
    names = {}
    ins = ("INSERT INTO RecallReach_Data.Dispense (DispenseId, SubjectId, HadmId, StartTime, Drug, DrugNorm, NDC, Strength, Form, Route, Dose, Discharge, HoldNextFill) "
           "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,0)")
    for d in disp:
        norm = vectors.normalize(d["drug"])
        key = d["drug"][:200].strip().lower()
        if key not in names:
            names[key] = [d["drug"][:200].strip(), 0]
        names[key][1] += 1
        iris.sql.exec(ins, d["id"], d["subject_id"], d["hadm_id"], d["starttime"], d["drug"][:200], norm[:200], d["ndc"],
                      d["strength"][:200], d["form"][:100], d["route"][:50], d["dose"][:100], d["discharge"][:100])
    for name, n in names.values():
        iris.sql.exec("INSERT INTO RecallReach_Data.DrugName (Name, Norm, Vec, Uses) VALUES (?,?,TO_VECTOR(?, DOUBLE, 128),?)",
                      name[:200], vectors.normalize(name)[:200], vectors.to_iris(vectors.embed(name)), n)
    return json.dumps({"patients": len(pats), "dispenses": len(disp), "drug_names": len(names)})
}

}
