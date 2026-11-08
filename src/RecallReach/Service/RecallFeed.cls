/// Business service: one FDA recall in, one RecallTriage session out.
Class RecallReach.Service.RecallFeed Extends Ens.BusinessService
{

Parameter ADAPTER = "RecallReach.Adapter.RecallFeedInboundAdapter";

Method OnProcessInput(pInput As Ens.StringContainer, Output pOutput As %RegisteredObject, ByRef pHint As %String) As %Status
{
    Set pInput = pInput.StringValue
    Set rec = ##class(RecallReach.Data.Recall).RecallIdxOpen(pInput)
    If '$ISOBJECT(rec) Quit $$$ERROR($$$GeneralError, "unknown recall "_pInput)
    Set rec.Status = "new", rec.ArrivedAt = ##class(RecallReach.Core.Config).Now(), rec.Error = ""
    $$$QuitOnError(rec.%Save())
    Set msg = ##class(RecallReach.Msg.RecallArrived).%New()
    Set msg.RecallNumber = pInput, msg.Source = ..Adapter.Source
    Set sc = ..SendRequestAsync("RecallTriage", msg)
    Set rec.SessionId = ..%SessionId
    Do rec.%Save()
    Do ##class(RecallReach.Data.Audit).Log("FDA feed", "recall.arrived", pInput, rec.Classification_" - "_$E(rec.ProductDescription, 1, 120), ..%SessionId,
        "Recall arrived: "_rec.Classification_", "_$P($P(rec.ProductDescription, ",", 1), ";", 1)_" (FDA report "_$E(rec.ReportDate,1,4)_"-"_$E(rec.ReportDate,5,6)_"-"_$E(rec.ReportDate,7,8)_")")
    Quit sc
}

}
