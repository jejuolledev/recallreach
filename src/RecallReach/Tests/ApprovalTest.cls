/// %UnitTest: approval expiry, single use, kill switch, plan validation, audit.
/// Run: do ##class(RecallReach.Tests.ApprovalTest).Run()
Class RecallReach.Tests.ApprovalTest Extends %UnitTest.TestCase
{

Parameter RN = "TEST-0001";

ClassMethod Run() As %Status
{
    Set ^UnitTestRoot = "/opt/recallreach/src"
    Quit ##class(%UnitTest.Manager).RunTest("RecallReach/Tests:RecallReach.Tests.ApprovalTest", "/noload/nodelete/nodisplay")
}

Method OnBeforeAllTests() As %Status
{
    Set ..Kill = $G(^RecallReach("KillSwitch"))
    Set ^RecallReach("UnitTest") = 1, ^RecallReach("KillSwitch") = 0
    Quit $$$OK
}

Property Kill As %Boolean;

Method OnAfterAllTests() As %Status
{
    Kill ^RecallReach("UnitTest")
    Set ^RecallReach("KillSwitch") = ..Kill
    Do ..Clean()
    Quit $$$OK
}

Method Clean()
{
    Set rn = ..#RN
    &sql(DELETE FROM RecallReach_Data.Recall WHERE RecallNumber = :rn)
    &sql(DELETE FROM RecallReach_Data.Approval WHERE RecallNumber = :rn)
    &sql(DELETE FROM RecallReach_Data.Contact WHERE RecallNumber = :rn)
    // test rows only (the app itself has no edit/delete path for audit rows)
    &sql(DELETE FROM RecallReach_Data.Audit WHERE RecallNumber = :rn OR Actor = 'unit test')
}

/// a recall in "ready" state with two ranked patients
Method MakeRecall()
{
    Do ..Clean()
    Set r = ##class(RecallReach.Data.Recall).%New()
    Set r.RecallNumber = ..#RN, r.Classification = "Class II", r.Status = "ready", r.ProductDescription = "Test tablets", r.Action = "hold_and_contact", r.Depth = "consumer"
    Do r.SourceJSON.Write({"recall_number": (..#RN)}.%ToJSON())
    Do r.ExtractionJSON.Write({"ndcs": ["00000000001"]}.%ToJSON())
    Do r.ResultJSON.Write({"shown": [{"subject_id": "P1", "p": 0.9, "exact": 0, "best": {"dispense_id": -1}}], "hidden": [{"subject_id": "P2", "p": 0.01, "exact": 0, "best": {"dispense_id": -2}}]}.%ToJSON())
    Do r.%Save()
}

Method TestTokenHashOnly()
{
    Do ..MakeRecall()
    Do $$$AssertStatusOK(##class(RecallReach.Core.Approvals).Create(..#RN, {"hold": ["P1"], "contact": ["P1"]}, .token, .id, .err))
    Do $$$AssertEquals(err, "")
    Do $$$AssertEquals($L(token), 48)
    Set a = ##class(RecallReach.Data.Approval).%OpenId(id)
    Do $$$AssertNotEquals(a.TokenHash, token, "raw token is not stored")
    Do $$$AssertEquals(a.TokenHash, ##class(RecallReach.Core.Approvals).Hash(token))
    Do $$$AssertEquals(##class(RecallReach.Core.Config).Diff(a.CreatedAt, a.ExpiresAt), 600, "expires 10 minutes after creation")
}

Method TestSingleUse()
{
    Do ..MakeRecall()
    Do ##class(RecallReach.Core.Approvals).Create(..#RN, {"hold": ["P1"], "contact": []}, .token, .id, .err)
    Set r1 = ##class(RecallReach.Core.Approvals).Decide(token, "approve")
    Do $$$AssertEquals(r1.ok, 1)
    Set r2 = ##class(RecallReach.Core.Approvals).Decide(token, "approve")
    Do $$$AssertEquals(r2.ok, 0)
    Do $$$AssertEquals(r2.code, 409, "second use refused")
    Set r3 = ##class(RecallReach.Core.Approvals).Decide(token, "reject", "changed my mind")
    Do $$$AssertEquals(r3.code, 409, "cannot reject after approve either")
}

Method TestExpiry()
{
    Do ..MakeRecall()
    Do ##class(RecallReach.Core.Approvals).Create(..#RN, {"hold": ["P1"], "contact": ["P1"]}, .token, .id, .err)
    Set a = ##class(RecallReach.Data.Approval).%OpenId(id)
    Set a.ExpiresAt = ##class(RecallReach.Core.Config).AddSeconds(##class(RecallReach.Core.Config).Now(), -1)
    Do a.%Save()
    Set r = ##class(RecallReach.Core.Approvals).Decide(token, "approve")
    Do $$$AssertEquals(r.code, 410, "expired link refused")
    Set a = ##class(RecallReach.Data.Approval).%OpenId(id)
    Do $$$AssertEquals(a.Status, "expired")
    Do $$$AssertEquals(a.UsedAt, "", "an expired link was never used")
}

Method TestNotYetExpiredAt599Seconds()
{
    Do ..MakeRecall()
    Do ##class(RecallReach.Core.Approvals).Create(..#RN, {"hold": ["P1"], "contact": []}, .token, .id, .err)
    Set a = ##class(RecallReach.Data.Approval).%OpenId(id)
    Set a.ExpiresAt = ##class(RecallReach.Core.Config).AddSeconds(##class(RecallReach.Core.Config).Now(), 2)
    Do a.%Save()
    Do $$$AssertEquals(##class(RecallReach.Core.Approvals).Decide(token, "approve").ok, 1)
}

Method TestKillSwitch()
{
    Do ..MakeRecall()
    Do ##class(RecallReach.Core.Approvals).Create(..#RN, {"hold": ["P1"], "contact": []}, .token, .id, .err)
    Do ##class(RecallReach.Core.Config).SetKill(1, "unit test", "test")
    Do $$$AssertTrue(##class(RecallReach.Core.Config).IsKilled())
    Set a = ##class(RecallReach.Data.Approval).%OpenId(id)
    Do $$$AssertEquals(a.Status, "cancelled", "pending approvals are cancelled when the kill switch goes on")
    Set r = ##class(RecallReach.Core.Approvals).Decide(token, "approve")
    Do $$$AssertEquals(r.code, 423, "nothing can be approved while killed")
    Do ##class(RecallReach.Core.Approvals).Create(..#RN, {"hold": ["P1"]}, .t2, .id2, .err2)
    Do $$$AssertTrue(err2 [ "Kill switch", "no new approval while killed")
    Set resp = ""
    Do ##class(RecallReach.Core.Config).SetKill(0, "unit test", "test")
    Do $$$AssertNotTrue(##class(RecallReach.Core.Config).IsKilled())
}

Method TestRejectNeedsReason()
{
    Do ..MakeRecall()
    Do ##class(RecallReach.Core.Approvals).Create(..#RN, {"hold": ["P1"], "contact": []}, .token, .id, .err)
    Do $$$AssertEquals(##class(RecallReach.Core.Approvals).Decide(token, "reject", "  ").code, 400)
    Set r = ##class(RecallReach.Core.Approvals).Decide(token, "reject", "Wrong strength on our shelf")
    Do $$$AssertEquals(r.status, "rejected")
}

Method TestPlanOnlyFromRankedList()
{
    Do ..MakeRecall()
    Do ##class(RecallReach.Core.Approvals).Create(..#RN, {"hold": ["P1", "INTRUDER"]}, .token, .id, .err)
    Do $$$AssertTrue(err [ "not on this recall", "unknown patient refused")
    Do ##class(RecallReach.Core.Approvals).Create(..#RN, {"hold": [], "contact": []}, .token, .id, .err)
    Do $$$AssertEquals(err, "nothing selected")
    Do ##class(RecallReach.Core.Approvals).Create(..#RN, {"hold": ["P2"], "contact": []}, .token, .id, .err)
    Do $$$AssertEquals(err, "", "a hidden (low-likelihood) patient can still be chosen by the pharmacist")
}

Method TestUnknownToken()
{
    Do $$$AssertEquals(##class(RecallReach.Core.Approvals).Decide("nope", "approve").code, 404)
}

Method TestShelfCheckRecallTakesNoPatientPlan()
{
    Do ..MakeRecall()
    Set r = ##class(RecallReach.Data.Recall).RecallIdxOpen(..#RN)
    Set r.Action = "stock_check", r.Depth = "retail" Do r.%Save()
    Do $$$AssertStatusOK(##class(RecallReach.Core.Approvals).Create(..#RN, {"hold": ["P1"], "contact": ["P1"]}, .token, .id, .err))
    Do $$$AssertTrue(err [ "shelf check", "a retail-level recall gets no patient calls or holds")
    Do $$$AssertEquals(token, "")
}

Method TestDuplicatePatientsCountOnce()
{
    Do ..MakeRecall()
    Do $$$AssertStatusOK(##class(RecallReach.Core.Approvals).Create(..#RN, {"hold": ["P1", "P1"], "contact": ["P1"]}, .token, .id, .err))
    Set a = ##class(RecallReach.Data.Approval).%OpenId(id)
    Do $$$AssertEquals({}.%FromJSON(a.ActionsJSON).hold.%Size(), 1)
}

Method TestAuditAppendOnly()
{
    Do ##class(RecallReach.Data.Audit).Log("unit test", "test.event", ..#RN, "x")
    &sql(SELECT MAX(ID) INTO :id FROM RecallReach_Data.Audit)
    Set a = ##class(RecallReach.Data.Audit).%OpenId(id)
    Set a.Detail = "tampered"
    Do $$$AssertStatusNotOK(a.%Save(), "audit rows cannot be edited")
}

Method TestReplayAndValidation()
{
    Set src = {"recall_number": "X-1", "classification": "Class I", "product_description": "Lisinopril tablets, USP 5mg (NDC 68084-060-01)", "code_info": "Lot#: 131928, Exp 09/30/2015", "distribution_pattern": "Nationwide"}.%ToJSON()
    Set reply = ##class(RecallReach.Core.Py).ReferenceReply(src)
    Set v = {}.%FromJSON(##class(RecallReach.Core.Py).Validate(src, reply))
    Do $$$AssertEquals(v.ndcs.%Get(0), "68084006001")
    Do $$$AssertEquals(v.action, "hold_and_contact")
    Do $$$AssertEquals(v.depth.value, "consumer")
    Set src2 = {"recall_number": "X-2", "classification": "Class II", "reason_for_recall": "CGMP Deviations: Firm did not adequately investigate customer complaints.", "product_description": "Lisinopril tablets, USP 5mg (NDC 68084-060-01)", "code_info": "Lot#: 131928, Exp 09/30/2015", "distribution_pattern": "Nationwide"}.%ToJSON()
    Set v2 = {}.%FromJSON(##class(RecallReach.Core.Py).Validate(src2, ##class(RecallReach.Core.Py).ReferenceReply(src2)))
    Do $$$AssertEquals(v2.action, "stock_check", "quality-only Class II recall: shelf check, no patient calls")
    Set bad = {}.%FromJSON(##class(RecallReach.Core.Py).Validate(src, "I cannot help with that"))
    Do $$$AssertTrue(bad.error [ "not valid JSON", "non-JSON agent reply is an error, not a silent pass")
}

Method TestGS1Bridge()
{
    Set p = {}.%FromJSON(##class(RecallReach.Core.Py).ParseGS1(##class(RecallReach.Core.Py).BuildGS1("68084006001", "131928", "2015-09-30", "S1")))
    Do $$$AssertEquals(p.lot, "131928")
    Do $$$AssertEquals(p.expiry, "2015-09-30")
    Set e = {}.%FromJSON(##class(RecallReach.Core.Py).ParseGS1("(10)ABC"))
    Do $$$AssertTrue(e.error '= "")
}

Method TestTimeHelpers()
{
    Do $$$AssertEquals(##class(RecallReach.Core.Config).AddSeconds("2026-11-08 23:59:30", 600), "2026-11-09 00:09:30")
    Do $$$AssertEquals(##class(RecallReach.Core.Config).Diff("2026-11-08 23:59:30", "2026-11-09 00:09:30"), 600)
}

}
