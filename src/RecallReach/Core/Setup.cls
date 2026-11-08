/// Install / reset. Called by iris.script at image build time.
Class RecallReach.Core.Setup
{

ClassMethod Run(dataDir As %String = "/opt/recallreach/data") As %Status
{
    Set sc = $$$OK
    Try {
        Write "loading data...", !
        Do ##class(RecallReach.Data.Patient).%KillExtent()
        Do ##class(RecallReach.Data.Dispense).%KillExtent()
        Do ##class(RecallReach.Data.DrugName).%KillExtent()
        Set out = ##class(RecallReach.Core.Py).LoadData(dataDir)
        Write out, !
        If out [ """error""" $$$ThrowStatus($$$ERROR($$$GeneralError, "data load failed"))
        $$$ThrowOnError(..LoadRecalls(dataDir))
        $$$ThrowOnError(..WebApps())
        Set ^RecallReach("Threshold") = 0.05
        Set ^RecallReach("KillSwitch") = 0
        $$$ThrowOnError(##class(Ens.Director).SetAutoStart("RecallReach.Production"))
    } Catch ex {
        Set sc = ex.AsStatus()
    }
    Quit sc
}

/// all shipped recalls go into the pool; history is processed on first start
ClassMethod LoadRecalls(dataDir As %String) As %Status
{
    Do ##class(RecallReach.Data.Recall).%KillExtent()
    Set arr = [].%FromJSONFile(dataDir_"/recalls.json")
    Set it = arr.%GetIterator()
    While it.%GetNext(.i, .r) {
        Set sc = ..AddRecall(r, "pool")
        If $$$ISERR(sc) Return sc
    }
    Set meta = {}.%FromJSONFile(dataDir_"/meta.json")
    Kill ^RecallReach("Meta")
    Set ^RecallReach("Meta") = meta.%ToJSON()
    Quit $$$OK
}

ClassMethod AddRecall(r As %DynamicObject, status As %String) As %Status
{
    Set rec = ##class(RecallReach.Data.Recall).%New()
    Set rec.RecallNumber = r."recall_number", rec.Classification = r.classification, rec.Firm = r."recalling_firm"
    Set rec.ProductDescription = r."product_description", rec.Reason = r."reason_for_recall"
    Set rec.ReportDate = r."report_date", rec.InitiationDate = r."recall_initiation_date", rec.Status = status
    Do rec.SourceJSON.Write(r.%ToJSON())
    Set rec.NoticeText = ##class(RecallReach.Core.Py).NoticeText(r.%ToJSON())
    Quit rec.%Save()
}

/// queue the demo history (first start) - runs through the real production
ClassMethod QueueHistory() As %Status
{
    Set meta = {}.%FromJSON(^RecallReach("Meta"))
    Set it = meta.history.%GetIterator()
    While it.%GetNext(.i, .rn) { Do ..Enqueue(rn) }
    Set ^RecallReach("QueuePos") = 0
    Quit $$$OK
}

ClassMethod Enqueue(rn As %String)
{
    Set ^RecallReach("Inbox", $I(^RecallReach("InboxSeq"))) = rn
}

/// next recall of the demo queue ("Simulate new FDA recall")
ClassMethod NextFromQueue() As %String
{
    Set meta = {}.%FromJSON(^RecallReach("Meta"))
    Set n = meta.queue.%Size()
    For k = 1:1:n {
        Set pos = $I(^RecallReach("QueuePos")) - 1
        Set rn = meta.queue.%Get(pos # n)
        Set rec = ##class(RecallReach.Data.Recall).RecallIdxOpen(rn)
        If $ISOBJECT(rec) && (rec.Status = "pool") Do ..Enqueue(rn) Quit
        Set rn = ""
    }
    Quit rn
}

ClassMethod WaitIdle(seconds As %Integer = 180) As %Status
{
    For i = 1:1:seconds {
        &sql(SELECT COUNT(*) INTO :busy FROM RecallReach_Data.Recall WHERE Status IN ('new', 'reading'))
        Quit:(busy = 0)&&($D(^RecallReach("Inbox")) = 0)
        Hang 1
    }
    Quit $$$OK
}

/// Demo reset: back to the start state (history processed, queue re-armed).
ClassMethod Reset() As %Status
{
    Set ^RecallReach("KillSwitch") = 0
    &sql(UPDATE RecallReach_Data.Approval SET Status = 'cancelled' WHERE Status = 'pending')
    Set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT ID FROM EnsLib_Workflow.TaskResponse WHERE TaskStatus_IsComplete = 0")
    While rs.%Next() { Set t = ##class(EnsLib.Workflow.TaskResponse).%OpenId(rs.%Get("ID")) Do:$ISOBJECT(t) t.CompleteTask("") }
    &sql(DELETE FROM RecallReach_Data.Approval)
    &sql(DELETE FROM RecallReach_Data.Contact)
    &sql(UPDATE RecallReach_Data.Dispense SET HoldNextFill = 0, HoldReason = NULL, Lot = NULL, LotExpiry = NULL, Serial = NULL, GTIN = NULL, LotCapturedAt = NULL WHERE HoldNextFill = 1 OR Lot IS NOT NULL)
    Set meta = {}.%FromJSON(^RecallReach("Meta"))
    Set it = meta.queue.%GetIterator()
    While it.%GetNext(.i, .rn) {
        &sql(UPDATE RecallReach_Data.Recall SET Status = 'pool', ArrivedAt = NULL WHERE RecallNumber = :rn)
    }
    Set it = meta.history.%GetIterator()
    While it.%GetNext(.i, .rn) {
        &sql(UPDATE RecallReach_Data.Recall SET Status = 'ready' WHERE RecallNumber = :rn AND Status <> 'pool' AND Status <> 'no_patients' AND Action = 'hold_and_contact')
        &sql(UPDATE RecallReach_Data.Recall SET Status = 'shelf_check', ShelfDoneAt = NULL WHERE RecallNumber = :rn AND Status <> 'pool' AND Action = 'stock_check')
    }
    Kill ^RecallReach("Inbox")
    Set ^RecallReach("QueuePos") = 0
    Do ##class(RecallReach.Data.Audit).Log("demo", "demo.reset", "", "demo data back to start state")
    Quit $$$OK
}

ClassMethod WebApps() As %Status
{
    Set ns = $NAMESPACE
    New $NAMESPACE
    Set $NAMESPACE = "%SYS"
    Set sc = $$$OK
    For app = "/recallreach/api", "/recallreach/replay", "/recallreach" {
        If ##class(Security.Applications).Exists(app) Do ##class(Security.Applications).Delete(app)
    }
    Kill p
    Set p("NameSpace") = ns, p("Enabled") = 1, p("AutheEnabled") = 64, p("MatchRoles") = ":%All", p("Description") = "RecallReach REST API"
    Set p("DispatchClass") = "RecallReach.API.REST", p("CSPZENEnabled") = 1
    $$$QuitOnError(##class(Security.Applications).Create("/recallreach/api", .p))
    Set p("DispatchClass") = "RecallReach.API.Replay", p("Description") = "RecallReach replay LLM endpoint (no key needed)"
    $$$QuitOnError(##class(Security.Applications).Create("/recallreach/replay", .p))
    Kill p
    Set p("NameSpace") = ns, p("Enabled") = 1, p("AutheEnabled") = 64, p("Path") = "/opt/recallreach/web/", p("ServeFiles") = 1
    Set p("Description") = "RecallReach UI", p("CSPZENEnabled") = 0, p("MatchRoles") = ":%All", p("Recurse") = 1
    $$$QuitOnError(##class(Security.Applications).Create("/recallreach", .p))
    If '##class(Security.SSLConfigs).Exists("RecallReachSSL") {
        Kill s Set s("Enabled") = 1
        Do ##class(Security.SSLConfigs).Create("RecallReachSSL", .s)
    }
    Quit sc
}

}
