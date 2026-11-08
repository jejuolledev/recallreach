/// Live accuracy run: needs ANTHROPIC_API_KEY. Each reply is recorded under
/// /opt/recallreach/recordings so the Accuracy page (and replay mode) can use it.
Class RecallReach.Core.Bench
{

ClassMethod Run(n As %Integer = 300) As %Status
{
    If ##class(RecallReach.Core.Config).Mode() '= "live" Write "ANTHROPIC_API_KEY is not set: nothing to measure.", ! Quit $$$OK
    Set meta = {}.%FromJSON(^RecallReach("Meta"))
    $$$QuitOnError(##class(Ens.Director).CreateBusinessService("BenchmarkRunner", .svc))
    Set it = meta.benchmark.%GetIterator(), done = 0, fail = 0
    While it.%GetNext(.i, .rn) && (done < n) {
        If ##class(%File).Exists(##class(RecallReach.Core.Config).#RECORDDIR_"/"_rn_".json") Continue
        If ##class(RecallReach.Core.Config).Spent() >= ##class(RecallReach.Core.Config).SpendCap() Write "spend cap reached", ! Quit
        Set req = ##class(RecallReach.Msg.AgentRequest).%New()
        Set req.RecallNumber = rn, req.SystemPrompt = ##class(RecallReach.Core.Py).SystemPrompt(), req.UserPrompt = ##class(RecallReach.Core.Flow).UserPrompt(rn)
        Set sc = svc.ProcessInput(req, .resp)
        Set done = done + 1
        If $$$ISERR(sc) Set fail = fail + 1 Write rn, " ERROR ", $SYSTEM.Status.GetErrorText(sc), !
        Else  Write rn, " ok ", resp.InputTokens, "+", resp.OutputTokens, " tokens $", $FN(resp.CostUSD, "", 5), !
    }
    Kill ^RecallReach("Accuracy")
    Write done, " calls, ", fail, " failed, spent $", $FN(##class(RecallReach.Core.Config).Spent(), "", 4), !
    Quit $$$OK
}

}
