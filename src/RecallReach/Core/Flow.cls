/// Small helpers called from the BPLs.
Class RecallReach.Core.Flow
{

ClassMethod SetStatus(recall As %String, status As %String, session As %Integer = "") As %Status
{
    Set rec = ##class(RecallReach.Data.Recall).RecallIdxOpen(recall)
    Quit:'$ISOBJECT(rec) $$$OK
    Set rec.Status = status
    Quit rec.%Save()
}

ClassMethod UserPrompt(recall As %String) As %String
{
    Set rec = ##class(RecallReach.Data.Recall).RecallIdxOpen(recall)
    Quit ##class(RecallReach.Core.Py).UserPrompt(##class(RecallReach.Core.Config).ReadStream(rec.SourceJSON))
}

ClassMethod Fail(recall As %String, sc As %Status, session As %Integer = "") As %Status
{
    Set rec = ##class(RecallReach.Data.Recall).RecallIdxOpen(recall)
    Quit:'$ISOBJECT(rec) $$$OK
    Set msg = $S($$$ISERR(sc):$SYSTEM.Status.GetErrorText(sc), 1:"unknown error")
    Set rec.Status = $S(msg["Kill switch":"stopped", 1:"error"), rec.Error = $E(msg, 1, 1000)
    Do rec.%Save()
    Quit ##class(RecallReach.Data.Audit).Log("RecallTriage", "recall."_rec.Status, recall, msg, session)
}

}
