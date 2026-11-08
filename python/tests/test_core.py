"""Unit tests for the pure-Python core (run with: python3 -m unittest discover -s python/tests).
Inside the container: /usr/irissys/bin/irispython -m unittest discover -s /opt/recallreach/python/tests"""
import datetime as dt
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
from recallreach_core import ndc, gs1, extract, probability, vectors, accuracy  # noqa: E402

# real openFDA record D-1226-2015 (public domain)
LISINOPRIL = {
    "recall_number": "D-1226-2015", "classification": "Class II", "recalling_firm": "American Health Packaging",
    "product_description": "Lisinopril tablets, USP 5mg packaged in 10-count blisters (NDC 68084-060-11); 10 blister packs per carton (NDC 68084-060-01); Rx only,  Manufactured by: Wockhardt Limited, Mumbai, India, Distributed by: Wockhardt, USA, LLC 20 Waterview Blvd. Parsippany, NJ 07054 USA for American Health Packaging 2550-A John Glenn Avenue, Columbus, OH 43217.",
    "reason_for_recall": "CGMP Deviations: Firm did not adequately investigate customer complaints.",
    "code_info": "Lot#: 131928, Exp 09/30/2015", "product_quantity": "4,718 cartons",
    "distribution_pattern": "Nationwide", "recall_initiation_date": "20150601", "report_date": "20150715",
    "openfda": {"package_ndc": [], "generic_name": []},
}
PAT = {"gender": "F", "anchor_age": 80, "anchor_year": 2155, "anchor_year_group": "2011-2013"}


class TestNDC(unittest.TestCase):
    def test_layouts(self):
        self.assertEqual(ndc.to_11("68084-060-01"), "68084006001")   # 5-3-2
        self.assertEqual(ndc.to_11("0409-4276-01"), "00409427601")   # 4-4-2
        self.assertEqual(ndc.to_11("51079-0451-2"), "51079045102")   # 5-4-1
        self.assertEqual(ndc.to_11("51079-0451-20"), "51079045120")  # already 5-4-2
        self.assertIsNone(ndc.to_11("123-45-6"))
        self.assertIsNone(ndc.to_11("abc"))

    def test_find_in_text_with_spans(self):
        t = "blisters (NDC 68084-060-11); carton (NDC 68084-060-01)"
        found = ndc.find_in_text(t)
        self.assertEqual([f[0] for f in found], ["68084006011", "68084006001"])
        self.assertEqual(t[found[0][1]:found[0][2]], "68084-060-11")

    def test_gtin(self):
        ten, cands = ndc.from_gtin14("00368084060018")
        self.assertEqual(ten, "6808406001")
        self.assertIn("68084006001", cands)


class TestGS1(unittest.TestCase):
    def test_human_readable(self):
        raw = gs1.build("68084006001", "131928", "2015-09-30", "SN123")
        p = gs1.parse(raw)
        self.assertEqual(p["lot"], "131928")
        self.assertEqual(p["expiry"], "2015-09-30")
        self.assertEqual(p["serial"], "SN123")
        self.assertTrue(p["gtin_check_ok"])
        self.assertIn("68084006001", p["ndc11_candidates"])

    def test_raw_with_group_separator(self):
        raw = "0100368084060018" + "17150930" + "10131928" + "\x1d" + "21SN9"
        p = gs1.parse(raw)
        self.assertEqual((p["lot"], p["serial"], p["expiry"]), ("131928", "SN9", "2015-09-30"))

    def test_textual_gs_and_symbology_prefix(self):
        p = gs1.parse("]d20100368084060018171509301013A<GS>21X1")
        self.assertEqual(p["lot"], "13A")
        self.assertEqual(p["serial"], "X1")

    def test_day_zero_means_end_of_month(self):
        self.assertEqual(gs1.expiry_to_iso("150200"), "2015-02-28")

    def test_errors(self):
        with self.assertRaises(gs1.GS1Error):
            gs1.parse("")
        with self.assertRaises(gs1.GS1Error):
            gs1.parse("(10)ABC")
        with self.assertRaises(gs1.GS1Error):
            gs1.parse("99XYZ")


class TestExtraction(unittest.TestCase):
    def test_reference_on_real_recall(self):
        v = extract.validate(LISINOPRIL, extract.reference_extract(LISINOPRIL))
        self.assertEqual(v["ingredient"], "Lisinopril")
        self.assertEqual(v["strength"], "5mg")
        self.assertEqual(v["form"], "tablet")
        self.assertEqual(v["ndcs"], ["68084006001", "68084006011"])
        self.assertEqual(v["lots"], [{"lot": "131928", "expiry": "2015-09-30"}])
        self.assertTrue(v["nationwide"])
        # "did not adequately investigate customer complaints": a process problem, so retail level, shelf check
        self.assertEqual(v["depth"]["value"], "retail")
        self.assertFalse(v["depth"]["stated"])
        self.assertEqual(v["action"], "stock_check")
        self.assertEqual(v["low_confidence"], 0)
        for f in v["fields"]:
            self.assertEqual(v["text"][f["start"]:f["end"]].lower(), f["evidence"].lower())

    def test_notice_never_contains_openfda_block(self):
        r = dict(LISINOPRIL, openfda={"package_ndc": ["9999-9999-99"]})
        self.assertNotIn("9999-9999-99", extract.notice_text(r))

    def test_hallucinated_evidence_is_flagged(self):
        data = extract.reference_extract(LISINOPRIL)
        data["ndcs"].append({"value": "12345-6789-01", "evidence": "NDC 12345-6789-01"})
        data["lots"] = [{"value": "ZZZ999", "expiry": "", "evidence": "Lot ZZZ999"}]
        v = extract.validate(LISINOPRIL, data)
        self.assertNotIn("12345678901", v["ndcs"])            # not used for matching
        self.assertEqual(v["lots"], [])
        bad = [f for f in v["fields"] if f["note"] == "evidence not found in notice"]
        self.assertEqual(len(bad), 2)

    def test_invalid_ndc_value(self):
        v = extract.validate(LISINOPRIL, {"ndcs": [{"value": "68084-060", "evidence": "68084-060"}]})
        self.assertEqual(v["ndcs"], [])

    def test_json_reply_parsing(self):
        self.assertEqual(extract.parse_json_reply('```json\n{"a": 1}\n```')["a"], 1)
        self.assertEqual(extract.parse_json_reply('Here you go: {"a": 2} thanks')["a"], 2)
        with self.assertRaises(ValueError):
            extract.parse_json_reply("no json here")

    def test_expiry_formats(self):
        self.assertEqual(extract.parse_expiry("09/30/2015"), "2015-09-30")
        self.assertEqual(extract.parse_expiry("10/14"), "2014-10-31")
        self.assertEqual(extract.parse_expiry("Feb 2016"), "2016-02-29")
        self.assertEqual(extract.parse_expiry("garbage"), "")

    def test_class3_is_stock_check(self):
        v = extract.reference_extract(dict(LISINOPRIL, classification="Class III"))
        self.assertEqual(v["decision"]["action"], "stock_check")


class TestRecallDepth(unittest.TestCase):
    def test_stated_depth_wins(self):
        r = dict(LISINOPRIL, reason_for_recall="Subpotent drug; recall to the retail level")
        d = extract.recall_depth(r)
        self.assertEqual((d["value"], d["stated"], d["evidence"]), ("retail", True, "retail level"))
        self.assertEqual(extract.recall_depth(dict(LISINOPRIL, code_info="Lot 1. Recalled to the consumer level."))["value"], "consumer")
        self.assertEqual(extract.recall_depth(dict(LISINOPRIL, code_info="wholesale level only"))["value"], "wholesale")

    def test_inferred_depth_rule(self):
        self.assertEqual(extract.recall_depth(dict(LISINOPRIL, classification="Class I"))["value"], "consumer")
        risk = dict(LISINOPRIL, reason_for_recall="CGMP Deviations: water may have been contaminated with Burkholderia cepacia.")
        self.assertEqual(extract.recall_depth(risk)["value"], "consumer")
        self.assertEqual(extract.recall_depth(LISINOPRIL)["value"], "retail")
        self.assertEqual(extract.recall_depth(dict(LISINOPRIL, classification="Class III"))["value"], "retail")
        self.assertIn("inferred", extract.recall_depth(LISINOPRIL)["basis"])

    def test_decision_follows_depth(self):
        tool = {"ndcs": [{"fills": 11, "patients": 7}], "ingredient_fills": 30}
        self.assertEqual(extract.reference_decide(LISINOPRIL, {"ndcs": ["x"]}, tool)["action"], "stock_check")
        risk = dict(LISINOPRIL, classification="Class I")
        self.assertEqual(extract.reference_decide(risk, {"ndcs": ["x"]}, tool)["action"], "hold_and_contact")
        none = {"ndcs": [{"fills": 0, "patients": 0}], "ingredient_fills": 0}
        self.assertEqual(extract.reference_decide(risk, {"ndcs": ["x"]}, none)["action"], "no_action")

    def test_singular_counts(self):
        tool = {"ndcs": [{"fills": 1, "patients": 1}], "ingredient_fills": 1}
        why = extract.reference_decide(dict(LISINOPRIL, classification="Class I"), {"ndcs": ["x"]}, tool)["rationale"]
        self.assertIn("1 fill of the recalled NDCs for 1 patient (1 fill", why)

    def test_guard_rail_no_patient_contact_below_consumer_level(self):
        data = extract.reference_extract(LISINOPRIL)
        data["decision"] = {"action": "hold_and_contact", "rationale": "call everyone"}
        v = extract.validate(LISINOPRIL, data)
        self.assertEqual(v["action"], "stock_check")

    def test_validator_fills_month_only_expiry(self):
        data = extract.reference_extract(LISINOPRIL)
        data["lots"] = [{"value": "131928", "expiry": "", "evidence": "Lot#: 131928, Exp 09/30/2015"}]
        v = extract.validate(LISINOPRIL, data)
        self.assertEqual(v["lots"], [{"lot": "131928", "expiry": "2015-09-30"}])
        self.assertTrue(any(f["note"].startswith("expiry filled") for f in v["fields"]))
        self.assertEqual(extract.parse_expiry("2019-11"), "2019-11-30")

    def test_agent_stated_depth_needs_evidence(self):
        data = extract.reference_extract(dict(LISINOPRIL, classification="Class I"))
        data["depth"] = {"value": "retail", "stated": True, "evidence": "retail level"}   # not in the notice
        v = extract.validate(dict(LISINOPRIL, classification="Class I"), data)
        self.assertEqual(v["depth"]["value"], "consumer")

    def test_states_distribution(self):
        v = extract.validate(dict(LISINOPRIL, distribution_pattern="Distributed in CA, NV and Texas."),
                             extract.reference_extract(dict(LISINOPRIL, distribution_pattern="Distributed in CA, NV and Texas.")))
        self.assertFalse(v["nationwide"])
        self.assertEqual(v["states"], ["CA", "NV", "TX"])


class TestProbability(unittest.TestCase):
    def setUp(self):
        self.v = extract.validate(LISINOPRIL, extract.reference_extract(LISINOPRIL))
        self.sdud = {"68084006001": {"2014Q1": 1000.0, "2014Q2": None}}

    def disp(self, **kw):
        d = {"id": 1, "subject_id": "1", "starttime": "2157-07-16 08:00:00", "drug": "Lisinopril",
             "ndc": "68084006001", "strength": "5mg Tablet", "lot": ""}
        d.update(kw)
        return d

    def test_mimic_real_date_window(self):
        lo, hi = probability.real_date_window("2157-07-16 08:00:00", 2155, "2011-2013")
        self.assertEqual((lo, hi), (dt.date(2013, 7, 16), dt.date(2016, 7, 16)))

    def test_lot_window_from_expiry(self):
        a, b, _ = probability.lot_window(self.v, LISINOPRIL)
        self.assertEqual((a, b), (dt.date(2013, 9, 30), dt.date(2015, 6, 1)))

    def test_overlap(self):
        self.assertAlmostEqual(probability.overlap(dt.date(2014, 1, 1), dt.date(2015, 1, 1), dt.date(2013, 1, 1), dt.date(2014, 7, 2)), 182 / 365, 3)
        self.assertEqual(probability.overlap(dt.date(2010, 1, 1), dt.date(2011, 1, 1), dt.date(2013, 1, 1), dt.date(2014, 1, 1)), 0.0)

    def test_units_and_lot_share_capped(self):
        self.assertEqual(probability.units_per_container(LISINOPRIL["product_description"]), 100)
        s, info = probability.lot_share(LISINOPRIL, self.v, ["68084006001"], self.sdud, (dt.date(2013, 9, 30), dt.date(2015, 6, 1)))
        self.assertEqual(s, 1.0)
        self.assertIn("capped", info["basis"])
        self.assertEqual(info["suppressed_quarters"], 1)

    def test_lot_share_heuristic_without_volume(self):
        s, info = probability.lot_share(LISINOPRIL, self.v, ["68084006001"], {}, (dt.date(2013, 9, 30), dt.date(2015, 6, 1)))
        self.assertEqual(s, probability.HEURISTIC_NO_VOLUME)
        self.assertEqual(info["source"], "heuristic")

    def test_exact_lot_confirmed_and_cleared(self):
        hit = probability.score_dispense(LISINOPRIL, self.v, self.disp(lot="131928"), PAT, {})
        miss = probability.score_dispense(LISINOPRIL, self.v, self.disp(lot="999999"), PAT, {})
        self.assertEqual((hit["p"], hit["exact"]), (1.0, True))
        self.assertIn("Lot confirmed", hit["badges"])
        self.assertEqual((miss["p"], miss["exact"]), (0.0, True))
        self.assertIn("Lot cleared", miss["badges"])

    def test_product_factor_levels(self):
        self.assertEqual(probability.product_factor(self.v, self.disp())[1], "ndc")
        self.assertEqual(probability.product_factor(self.v, self.disp(ndc="68084006099"))[1], "product")
        f, kind, _ = probability.product_factor(self.v, self.disp(ndc="00172375810"))
        self.assertEqual((f, kind), (probability.WRONG_NDC_RATE, "ingredient"))
        f, _, _ = probability.product_factor(self.v, self.disp(ndc="00172375810", strength="20mg Tablet"))
        self.assertEqual(f, probability.OTHER_STRENGTH)

    def test_region(self):
        self.assertEqual(probability.region_factor({"nationwide": True})[0], 1.0)
        self.assertEqual(probability.region_factor({"states": ["MA", "NY"]})[0], 1.0)
        self.assertEqual(probability.region_factor({"states": ["CA"]})[0], probability.REGION_OUTSIDE)
        self.assertEqual(probability.region_factor({})[0], probability.REGION_UNKNOWN)

    def test_rank_one_list_with_hidden_tail(self):
        disps = [self.disp(id=1, subject_id="A"), self.disp(id=2, subject_id="A", starttime="2156-01-01 00:00:00"),
                 self.disp(id=3, subject_id="B"), self.disp(id=4, subject_id="C", ndc="00172375810"),
                 self.disp(id=5, subject_id="D", lot="131928")]
        pats = {k: PAT for k in "ABCD"}
        out = probability.rank_patients(LISINOPRIL, self.v, disps, pats, self.sdud, 0.05)
        ids = [r["subject_id"] for r in out["shown"]]
        self.assertEqual(ids[0], "D")                     # barcode lot = exact 100%
        self.assertEqual(ids[1], "A")                     # two fills beat one
        self.assertGreater(out["shown"][1]["p"], out["shown"][2]["p"])
        self.assertEqual([r["subject_id"] for r in out["hidden"]], ["C"])
        self.assertEqual(out["total"], 4)
        for r in out["shown"] + out["hidden"]:
            self.assertTrue(0.0 <= r["p"] <= 1.0)
            if not r["exact"]:
                self.assertLessEqual(r["p"], probability.ESTIMATE_CAP)

    def test_estimate_never_shown_as_exact(self):
        # many fills, product 1.0 x lot share 1.0 x region 1.0: the estimate can reach 1.0, but it is not a scanned lot
        disps = [self.disp(id=i, subject_id="A", starttime="2157-07-%02d 08:00:00" % (i + 1)) for i in range(11)]
        row = probability.rank_patients(LISINOPRIL, self.v, disps, {"A": dict(PAT, anchor_year_group="2014-2014")},
                                        {"68084006001": {"2014Q1": 1.0}}, 0)["shown"][0]
        self.assertFalse(row["exact"])
        self.assertLessEqual(row["p"], probability.ESTIMATE_CAP)
        self.assertNotIn("Lot confirmed", row["badges"])


class TestSharedShift(unittest.TestCase):
    def test_same_day_fills_do_not_compound(self):
        v = extract.validate(LISINOPRIL, extract.reference_extract(LISINOPRIL))
        d1 = {"id": 1, "subject_id": "A", "starttime": "2157-07-16 08:00:00", "drug": "Lisinopril", "ndc": "68084006001", "strength": "5mg", "lot": ""}
        d2 = dict(d1, id=2)
        one = probability.rank_patients(LISINOPRIL, v, [d1], {"A": PAT}, {"68084006001": {"2014Q1": 1.0}}, 0)["shown"][0]["p"]
        two = probability.rank_patients(LISINOPRIL, v, [d1, d2], {"A": PAT}, {"68084006001": {"2014Q1": 1.0}}, 0)["shown"][0]["p"]
        # one shared MIMIC date shift: a second fill on the same day cannot double the time chance
        self.assertAlmostEqual(one, two, 2)

    def test_cleared_lot_is_not_exact_when_other_fills_remain(self):
        v = extract.validate(LISINOPRIL, extract.reference_extract(LISINOPRIL))
        d1 = {"id": 1, "subject_id": "A", "starttime": "2157-07-16 08:00:00", "drug": "Lisinopril", "ndc": "68084006001", "strength": "5mg", "lot": "999"}
        d2 = dict(d1, id=2, lot="", starttime="2157-03-01 08:00:00")
        row = probability.rank_patients(LISINOPRIL, v, [d1, d2], {"A": PAT}, {}, 0)["shown"][0]
        self.assertFalse(row["exact"])
        self.assertGreater(row["p"], 0)


class TestVectors(unittest.TestCase):
    def test_same_ingredient_scores_high(self):
        a = vectors.embed("Lisinopril tablets, USP")
        self.assertGreater(vectors.cosine(a, vectors.embed("Lisinopril")), 0.99)
        self.assertLess(vectors.cosine(a, vectors.embed("Amlodipine")), 0.5)
        self.assertEqual(len(a), vectors.DIM)


class TestAccuracy(unittest.TestCase):
    def test_score_one(self):
        r = dict(LISINOPRIL, openfda={"package_ndc": ["68084-060-01"], "product_ndc": ["68084-060"], "generic_name": ["LISINOPRIL"]})
        v = extract.validate(r, extract.reference_extract(r))
        s = accuracy.score_one(r, v)
        self.assertTrue(s["package_hit"] and s["product_hit"] and s["ingredient_hit"])
        self.assertEqual(s["extra_wrong"], [])


if __name__ == "__main__":
    unittest.main()
