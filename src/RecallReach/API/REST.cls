/// RecallReach REST API (/recallreach/api). No login: demo data only
/// (MIMIC-IV demo patients, public openFDA recalls).
Class RecallReach.API.REST Extends %CSP.REST
{

Parameter CONTENTTYPE = "application/json";

Parameter CHARSET = "utf-8";

Parameter HandleCorsRequest = 0;

XData UrlMap [ XMLNamespace = "http://www.intersystems.com/urlmap" ]
{
<Routes>
  <Route Url="/status" Method="GET" Call="Status" />
  <Route Url="/recalls" Method="GET" Call="Recalls" />
  <Route Url="/recalls/:rn" Method="GET" Call="Recall" />
  <Route Url="/recalls/:rn/patients" Method="GET" Call="Patients" />
  <Route Url="/recalls/:rn/approval" Method="POST" Call="RequestApproval" />
  <Route Url="/feed/next" Method="POST" Call="FeedNext" />
  <Route Url="/approvals/:token" Method="GET" Call="Approval" />
  <Route Url="/approvals/:token/approve" Method="POST" Call="Approve" />
  <Route Url="/approvals/:token/reject" Method="POST" Call="Reject" />
  <Route Url="/killswitch" Method="GET" Call="Kill" />
  <Route Url="/killswitch" Method="POST" Call="SetKill" />
  <Route Url="/barcode/parse" Method="POST" Call="BarcodeParse" />
  <Route Url="/barcode/record" Method="POST" Call="BarcodeRecord" />
  <Route Url="/barcode/sample" Method="GET" Call="BarcodeSample" />
  <Route Url="/dispenses" Method="GET" Call="Dispenses" />
  <Route Url="/accuracy" Method="GET" Call="Accuracy" />
  <Route Url="/audit" Method="GET" Call="Audit" />
  <Route Url="/llmcalls" Method="GET" Call="LLMCalls" />
  <Route Url="/demo/reset" Method="POST" Call="Reset" />
</Routes>
}

ClassMethod Out(obj, code As %Integer = 200) As %Status
{
    Set %response.Status = code
    Do %response.SetHeader("Cache-Control", "no-store")
    Write obj.%ToJSON()
    Quit $$$OK
}

ClassMethod Err(code As %Integer, msg As %String) As %Status
{
    Quit ..Out({"error": (msg)}, code)
}

ClassMethod Body() As %DynamicObject
{
    Try {
        If $ISOBJECT(%request.Content) && (%request.Content.Size > 0) && (%request.Content.Size < 100000) {
            Return {}.%FromJSON(%request.Content)
        }
    } Catch {}
    Quit {}
}

ClassMethod Status() As %Status
{
    Set cfg = "RecallReach.Core.Config"
    Set o = {"mode": ($classmethod(cfg, "Mode")), "provider": "anthropic", "model": ($classmethod(cfg, "Model")),
        "killswitch": ($classmethod(cfg, "IsKilled")), "spent_usd": ($classmethod(cfg, "Spent")), "spend_cap_usd": ($classmethod(cfg, "SpendCap")),
        "threshold": ($classmethod(cfg, "Threshold")), "approval_seconds": (##class(RecallReach.Core.Config).#APPROVALSECONDS),
        "iris": ($ZV), "namespace": ($NAMESPACE),
        "production_running": (##class(Ens.Director).IsProductionRunning()), "queue_left": 0}
    Set meta = {}.%FromJSON($G(^RecallReach("Meta"), "{}"))
    If $ISOBJECT(meta.queue) {
        Set n = 0, it = meta.queue.%GetIterator()
        While it.%GetNext(.i, .rn) { &sql(SELECT COUNT(*) INTO :c FROM RecallReach_Data.Recall WHERE RecallNumber = :rn AND Status = 'pool') Set n = n + c }
        Set o."queue_left" = n
    }
    Quit ..Out(o)
}

ClassMethod Row(r As RecallReach.Data.Recall) As %DynamicObject
{
    Quit {"recall_number": (r.RecallNumber), "classification": (r.Classification), "firm": (r.Firm),
        "product": (r.ProductDescription), "reason": (r.Reason), "status": (r.Status), "arrived_at": (r.ArrivedAt),
        "report_date": (r.ReportDate), "initiation_date": (r.InitiationDate), "action": (r.Action), "rationale": (r.Rationale),
        "shown": (r.PatientsShown), "hidden": (r.PatientsHidden), "top_p": (r.TopP), "top_subject": (r.TopSubject),
        "source": (r.ExtractorSource), "model": (r.Model), "low_confidence": (r.LowConfidence), "session_id": (r.SessionId), "error": (r.Error)}
}

ClassMethod Recalls() As %Status
{
    Set arr = []
    Set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT ID FROM RecallReach_Data.Recall WHERE Status <> 'pool' ORDER BY ArrivedAt DESC, ID DESC")
    While rs.%Next() {
        Set r = ##class(RecallReach.Data.Recall).%OpenId(rs.%Get("ID"))
        Do arr.%Push(..Row(r))
    }
    Quit ..Out({"recalls": (arr), "now": (##class(RecallReach.Core.Config).Now())})
}

ClassMethod Recall(rn As %String) As %Status
{
    Set r = ##class(RecallReach.Data.Recall).RecallIdxOpen(rn)
    If '$ISOBJECT(r) || (r.Status = "pool") Quit ..Err(404, "recall not found")
    Set o = ..Row(r)
    Set o.notice = r.NoticeText
    Set ex = ##class(RecallReach.Core.Config).ReadStream(r.ExtractionJSON)
    If ex '= "" {
        Set e = {}.%FromJSON(ex)
        Do e.%Remove("text")
        Set o.extraction = e
    }
    Set src = {}.%FromJSON(##class(RecallReach.Core.Config).ReadStream(r.SourceJSON))
    Set o.fda = {"quantity": (src."product_quantity"), "distribution": (src."distribution_pattern"), "code_info": (src."code_info"),
        "url": ("https://api.fda.gov/drug/enforcement.json?search=recall_number:%22"_rn_"%22")}
    Set o.approval = ""
    Set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT TOP 1 ID FROM RecallReach_Data.Approval WHERE RecallNumber = ? ORDER BY ID DESC", rn)
    If rs.%Next() {
        Set a = ##class(RecallReach.Data.Approval).%OpenId(rs.%Get("ID"))
        Set o.approval = ##class(RecallReach.Core.Approvals).ToJSON(a)
    }
    Quit ..Out(o)
}

ClassMethod Patients(rn As %String) As %Status
{
    Set r = ##class(RecallReach.Data.Recall).RecallIdxOpen(rn)
    If '$ISOBJECT(r) || (r.Status = "pool") Quit ..Err(404, "recall not found")
    Set res = ##class(RecallReach.Core.Config).ReadStream(r.ResultJSON)
    If res = "" Quit ..Out({"recall_number": (rn), "status": (r.Status), "shown": [], "hidden": [], "total": 0})
    Set o = {}.%FromJSON(res)
    Set o."recall_number" = rn, o.status = r.Status
    // current hold flags
    For list = o.shown, o.hidden {
        Set it = list.%GetIterator()
        While it.%GetNext(.i, .row) {
            Set sid = row."subject_id", h = 0
            &sql(SELECT COUNT(*) INTO :h FROM RecallReach_Data.Dispense WHERE SubjectId = :sid AND HoldNextFill = 1 AND HoldReason = :rn)
            Set row."on_hold" = (h > 0)
            &sql(SELECT COUNT(*) INTO :h FROM RecallReach_Data.Contact WHERE SubjectId = :sid AND RecallNumber = :rn)
            Set row."on_contact_list" = (h > 0)
        }
    }
    Quit ..Out(o)
}

ClassMethod FeedNext() As %Status
{
    If ##class(RecallReach.Core.Config).IsKilled() Quit ..Err(423, "Kill switch is ON: no new recalls are taken in.")
    Set rn = ##class(RecallReach.Core.Setup).NextFromQueue()
    If rn = "" Quit ..Err(409, "No more recalls in the demo queue. Use Reset demo.")
    Quit ..Out({"queued": (rn)})
}

ClassMethod RequestApproval(rn As %String) As %Status
{
    Set b = ..Body()
    Set sc = ##class(RecallReach.Core.Approvals).Create(rn, b, .token, .id, .err)
    If $$$ISERR(sc) Quit ..Err(500, $SYSTEM.Status.GetErrorText(sc))
    If err '= "" Quit ..Err($S(err["Kill":423, 1:400), err)
    Set sc = ##class(RecallReach.Core.Approvals).Dispatch(id)
    If $$$ISERR(sc) Quit ..Err(500, $SYSTEM.Status.GetErrorText(sc))
    Set a = ##class(RecallReach.Data.Approval).%OpenId(id)
    Set o = ##class(RecallReach.Core.Approvals).ToJSON(a)
    Set o.token = token
    Quit ..Out(o, 201)
}

ClassMethod Approval(token As %String) As %Status
{
    Set a = ##class(RecallReach.Data.Approval).TokenIdxOpen(##class(RecallReach.Core.Approvals).Hash(token))
    If '$ISOBJECT(a) Quit ..Err(404, "This approval link is not valid.")
    Set o = ##class(RecallReach.Core.Approvals).ToJSON(a)
    Set r = ##class(RecallReach.Data.Recall).RecallIdxOpen(a.RecallNumber)
    Set o.recall = ..Row(r)
    Quit ..Out(o)
}

ClassMethod Approve(token As %String) As %Status
{
    Set res = ##class(RecallReach.Core.Approvals).Decide(token, "approve", "", "pharmacist (demo)")
    If 'res.ok Quit ..Err(res.code, res.error)
    Quit ..Out(res)
}

ClassMethod Reject(token As %String) As %Status
{
    Set b = ..Body()
    Set res = ##class(RecallReach.Core.Approvals).Decide(token, "reject", b.reason, "pharmacist (demo)")
    If 'res.ok Quit ..Err(res.code, res.error)
    Quit ..Out(res)
}

ClassMethod Kill() As %Status
{
    Quit ..Out({"on": (##class(RecallReach.Core.Config).IsKilled())})
}

ClassMethod SetKill() As %Status
{
    Set b = ..Body()
    Do ##class(RecallReach.Core.Config).SetKill(''b.on, "pharmacist (demo)", b.reason)
    Quit ..Out({"on": (##class(RecallReach.Core.Config).IsKilled())})
}

ClassMethod BarcodeParse() As %Status
{
    Set b = ..Body()
    Set o = {}.%FromJSON(##class(RecallReach.Core.Py).ParseGS1(b.raw))
    If o.error '= "" Quit ..Out(o, 400)
    // which of the 11-digit candidates exist in our records?
    Set o.matches = []
    Set it = o."ndc11_candidates".%GetIterator()
    While it.%GetNext(.i, .n) {
        &sql(SELECT COUNT(*), MAX(Drug) INTO :c, :drug FROM RecallReach_Data.Dispense WHERE NDC = :n)
        If c > 0 Do o.matches.%Push({"ndc11": (n), "fills": (c), "drug": (drug)})
    }
    Quit ..Out(o)
}

/// Record a scanned lot on a dispensing record (NDC on the barcode must match the record).
ClassMethod BarcodeRecord() As %Status
{
    If ##class(RecallReach.Core.Config).IsKilled() Quit ..Err(423, "Kill switch is ON")
    Set b = ..Body()
    Set o = {}.%FromJSON(##class(RecallReach.Core.Py).ParseGS1(b.raw))
    If o.error '= "" Quit ..Err(400, o.error)
    Set d = ##class(RecallReach.Data.Dispense).DispIdxOpen(+b."dispense_id")
    If '$ISOBJECT(d) Quit ..Err(404, "dispensing record not found")
    Set ok = 0, it = o."ndc11_candidates".%GetIterator()
    While it.%GetNext(.i, .n) { Set:n=d.NDC ok = 1 }
    If 'ok Quit ..Err(409, "The barcode is for a different product (NDC) than this dispensing record.")
    If o.lot = "" Quit ..Err(400, "The barcode has no lot number (10).")
    Set d.Lot = $ZCVT(o.lot, "U"), d.LotExpiry = o.expiry, d.Serial = o.serial, d.GTIN = o.gtin, d.LotCapturedAt = ##class(RecallReach.Core.Config).Now()
    $$$QuitOnError(d.%Save())
    Do ##class(RecallReach.Data.Audit).Log("pharmacist (demo)", "lot.captured", "", "fill "_d.DispenseId_" (patient "_d.SubjectId_"): NDC "_d.NDC_" lot "_d.Lot_" exp "_d.LotExpiry_" serial "_d.Serial)
    // re-rank every arrived recall that lists this NDC so "Lot confirmed" shows up at once
    Set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT RecallNumber FROM RecallReach_Data.Recall WHERE Status IN ('ready','expired','rejected')")
    While rs.%Next() {
        Set r = ##class(RecallReach.Data.Recall).RecallIdxOpen(rs.%Get("RecallNumber"))
        If ##class(RecallReach.Core.Config).ReadStream(r.ExtractionJSON) [ d.NDC {
            Set out = ##class(RecallReach.Core.Py).Match(##class(RecallReach.Core.Config).ReadStream(r.SourceJSON), ##class(RecallReach.Core.Config).ReadStream(r.ExtractionJSON),
                ##class(RecallReach.Core.Config).#DATADIR_"/sdud_cache.json", ##class(RecallReach.Core.Config).Threshold())
            Set j = {}.%FromJSON(out)
            Do r.ResultJSON.Clear() Do r.ResultJSON.Write(out)
            Set r.PatientsShown = j.shown.%Size(), r.PatientsHidden = j.hidden.%Size()
            If j.shown.%Size() Set r.TopSubject = j.shown.%Get(0)."subject_id", r.TopP = j.shown.%Get(0).p
            Do r.%Save()
        }
    }
    Quit ..Out({"ok": 1, "dispense_id": (d.DispenseId), "subject_id": (d.SubjectId), "lot": (d.Lot), "expiry": (d.LotExpiry), "serial": (d.Serial), "ndc": (d.NDC)})
}

/// A printable sample barcode for the demo (the recalled lot of the video recall).
ClassMethod BarcodeSample() As %Status
{
    Set ndc = $G(%request.Data("ndc", 1), "68084006001"), lot = $G(%request.Data("lot", 1), "131928"), exp = $G(%request.Data("exp", 1), "2015-09-30")
    Set raw = ##class(RecallReach.Core.Py).BuildGS1(ndc, lot, exp, "RR"_$R(900000)+100000)
    Quit ..Out({"raw": (raw), "ndc11": (ndc), "lot": (lot), "expiry": (exp), "note": "Sample generated by RecallReach for the demo; not a real package serial."})
}

ClassMethod Dispenses() As %Status
{
    Set ndc = $G(%request.Data("ndc", 1)), sid = $G(%request.Data("subject", 1))
    Set arr = []
    If ndc '= "" {
        Set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT TOP 50 DispenseId, SubjectId, StartTime, Drug, NDC, Strength, Lot, LotExpiry FROM RecallReach_Data.Dispense WHERE NDC = ? ORDER BY SubjectId, StartTime", ndc)
    } Else {
        Set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT TOP 50 DispenseId, SubjectId, StartTime, Drug, NDC, Strength, Lot, LotExpiry FROM RecallReach_Data.Dispense WHERE SubjectId = ? AND NDC IS NOT NULL ORDER BY StartTime", sid)
    }
    While rs.%Next() {
        Do arr.%Push({"dispense_id": (rs.%Get("DispenseId")), "subject_id": (rs.%Get("SubjectId")), "starttime": (rs.%Get("StartTime")),
            "drug": (rs.%Get("Drug")), "ndc": (rs.%Get("NDC")), "strength": (rs.%Get("Strength")), "lot": (rs.%Get("Lot")), "lot_expiry": (rs.%Get("LotExpiry"))})
    }
    Quit ..Out({"dispenses": (arr)})
}

ClassMethod Accuracy() As %Status
{
    Set cfg = "RecallReach.Core.Config"
    If ($G(^RecallReach("Accuracy")) = "") || $D(%request.Data("refresh", 1)) {
        Set ^RecallReach("Accuracy") = ##class(RecallReach.Core.Py).Accuracy(##class(RecallReach.Core.Config).#DATADIR, ##class(RecallReach.Core.Config).#RECORDDIR)
    }
    Set o = {}.%FromJSON(^RecallReach("Accuracy"))
    Quit ..Out(o)
}

ClassMethod Audit() As %Status
{
    Set rn = $G(%request.Data("recall", 1))
    Set arr = []
    If rn '= "" {
        Set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT TOP 300 ID, TS, Actor, Event, RecallNumber, Detail, SessionId FROM RecallReach_Data.Audit WHERE RecallNumber = ? ORDER BY ID DESC", rn)
    } Else {
        Set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT TOP 300 ID, TS, Actor, Event, RecallNumber, Detail, SessionId FROM RecallReach_Data.Audit ORDER BY ID DESC")
    }
    While rs.%Next() {
        Do arr.%Push({"id": (rs.%Get("ID")), "ts": (rs.%Get("TS")), "actor": (rs.%Get("Actor")), "event": (rs.%Get("Event")),
            "recall_number": (rs.%Get("RecallNumber")), "detail": (rs.%Get("Detail")), "session_id": (rs.%Get("SessionId"))})
    }
    Quit ..Out({"events": (arr), "trace_url": "/csp/user/EnsPortal.VisualTrace.zen?SESSIONID="})
}

ClassMethod LLMCalls() As %Status
{
    Set arr = []
    Set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT TOP 100 TS, RecallNumber, Mode, Model, InputTokens, OutputTokens, CostUSD, LatencyMs, OK, Error, SessionId FROM RecallReach_Data.LLMCall ORDER BY ID DESC")
    While rs.%Next() {
        Do arr.%Push({"ts": (rs.%Get("TS")), "recall_number": (rs.%Get("RecallNumber")), "mode": (rs.%Get("Mode")), "model": (rs.%Get("Model")),
            "input_tokens": (rs.%Get("InputTokens")), "output_tokens": (rs.%Get("OutputTokens")), "cost_usd": (rs.%Get("CostUSD")),
            "latency_ms": (rs.%Get("LatencyMs")), "ok": (rs.%Get("OK")), "error": (rs.%Get("Error")), "session_id": (rs.%Get("SessionId"))})
    }
    Quit ..Out({"calls": (arr), "spent_usd": (##class(RecallReach.Core.Config).Spent())})
}

ClassMethod Reset() As %Status
{
    $$$QuitOnError(##class(RecallReach.Core.Setup).Reset())
    Quit ..Out({"ok": 1})
}

}
