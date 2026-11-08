/// Business operation for the stock_check branch: a retail- or wholesale-level
/// recall does not reach patients, so instead of ranking patients RecallReach
/// writes one shelf task: which lots of which NDCs to pull and quarantine.
/// No patient is called and no next fill is changed.
Class RecallReach.Operation.ShelfCheck Extends Ens.BusinessOperation
{

Parameter INVOCATION = "Queue";

Method Create(req As RecallReach.Msg.ShelfCheckRequest, Output resp As RecallReach.Msg.ShelfCheckResponse) As %Status
{
    Set resp = ##class(RecallReach.Msg.ShelfCheckResponse).%New()
    Set resp.RecallNumber = req.RecallNumber
    If ##class(RecallReach.Core.Config).IsKilled() Quit $$$ERROR($$$GeneralError, "Kill switch is ON: no task is created")
    Set rec = ##class(RecallReach.Data.Recall).RecallIdxOpen(req.RecallNumber)
    If '$ISOBJECT(rec) Quit $$$ERROR($$$GeneralError, "unknown recall")
    Set ex = {}.%FromJSON(##class(RecallReach.Core.Config).ReadStream(rec.ExtractionJSON))
    Set lots = [], lotText = "", ndcText = "", ndcs = []
    Set it = ex.lots.%GetIterator()
    While it.%GetNext(.i, .l) {
        Do lots.%Push({"lot": (l.lot), "expiry": (l.expiry)})
        Set lotText = lotText_$S(lotText="":"", 1:", ")_l.lot_$S(l.expiry'="":" (exp "_l.expiry_")", 1:"")
    }
    If ex."all_lots" Set lotText = "all lots"
    Set it = ex.ndcs.%GetIterator()
    While it.%GetNext(.i, .n) {
        Set pn = $E(n,1,5)_"-"_$E(n,6,9)_"-"_$E(n,10,11)
        Do ndcs.%Push(pn)
        Set ndcText = ndcText_$S(ndcText="":"", 1:", ")_pn
    }
    Set task = {"depth": (req.Depth), "lots": (lots), "all_lots": (''ex."all_lots"), "ndcs": (ndcs), "created_at": (##class(RecallReach.Core.Config).Now()),
        "steps": ["Pull every unit of the listed lots from the shelf and the back stock.", "Quarantine them, labelled 'recalled - do not dispense'.", "Return or destroy them as the recalling firm instructs."],
        "not_done": ("No patient is called and no next fill is changed: this recall stops at the "_req.Depth_" level.")}
    Set rec.ShelfTaskJSON = task.%ToJSON(), rec.ShelfDoneAt = "", rec.PatientsShown = 0, rec.PatientsHidden = 0, rec.TopP = 0, rec.TopSubject = ""
    Do rec.ResultJSON.Clear()
    $$$QuitOnError(rec.%Save())
    Set resp.Lots = lotText, resp.NDCs = ndcText
    Do ##class(RecallReach.Data.Audit).Log("ShelfCheck", "shelf.task", req.RecallNumber, task.%ToJSON(), ..%SessionId,
        "Shelf check created ("_req.Depth_"-level recall): pull lot"_$S($L(lotText,",")>1:"s", 1:"")_" "_$S(lotText'="":lotText, 1:"(not stated)")_" of NDC "_$S(ndcText'="":ndcText, 1:"(not stated)")_". No patient calls.")
    Quit $$$OK
}

XData MessageMap
{
<MapItems>
  <MapItem MessageType="RecallReach.Msg.ShelfCheckRequest"><Method>Create</Method></MapItem>
</MapItems>
}

}
