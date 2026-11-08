/// Business operation: executes a pharmacist-approved plan. Re-checks the kill
/// switch and that the approval really is approved, then flags next fills on hold
/// and writes the contact list.
Class RecallReach.Operation.ActionExecutor Extends Ens.BusinessOperation
{

Parameter INVOCATION = "Queue";

Method Execute(req As RecallReach.Msg.ActionRequest, Output resp As RecallReach.Msg.ActionResponse) As %Status
{
    Set resp = ##class(RecallReach.Msg.ActionResponse).%New()
    Set appr = ##class(RecallReach.Data.Approval).%OpenId(req.ApprovalId)
    If '$ISOBJECT(appr) Quit $$$ERROR($$$GeneralError, "unknown approval")
    If ##class(RecallReach.Core.Config).IsKilled() {
        Set resp.Refused = "kill switch is on"
        Do ##class(RecallReach.Data.Audit).Log("kill switch", "action.refused", appr.RecallNumber, "approved plan not executed", ..%SessionId, "Kill switch is on: the approved plan was not carried out")
        Quit $$$OK
    }
    If appr.Status '= "approved" {
        Set resp.Refused = "approval status is "_appr.Status
        Quit $$$OK
    }
    Set plan = {}.%FromJSON(appr.ActionsJSON)
    Set rec = ##class(RecallReach.Data.Recall).RecallIdxOpen(appr.RecallNumber)
    Set result = {}.%FromJSON(##class(RecallReach.Core.Config).ReadStream(rec.ResultJSON))
    // index candidate rows by subject
    Set it = result.shown.%GetIterator()
    While it.%GetNext(.i, .row) { Set cand(row."subject_id") = row }
    Set it = result.hidden.%GetIterator()
    While it.%GetNext(.i, .row) { Set cand(row."subject_id") = row }
    Set ndcs = {}.%FromJSON(##class(RecallReach.Core.Config).ReadStream(rec.ExtractionJSON)).ndcs
    Set holds = 0, contacts = 0, rn = appr.RecallNumber
    Set it = plan.hold.%GetIterator()
    While it.%GetNext(.i, .sid) {
        Continue:'$D(cand(sid))
        Continue:$D(done("h", sid))
        Set done("h", sid) = 1
        Set itn = ndcs.%GetIterator()
        While itn.%GetNext(.j, .ndc) {
            &sql(UPDATE RecallReach_Data.Dispense SET HoldNextFill = 1, HoldReason = :rn WHERE SubjectId = :sid AND NDC = :ndc)
        }
        // ingredient-only matches: hold the fill that scored best
        Set did = cand(sid).best."dispense_id"
        &sql(UPDATE RecallReach_Data.Dispense SET HoldNextFill = 1, HoldReason = :rn WHERE DispenseId = :did)
        Set holds = holds + 1
    }
    Set it = plan.contact.%GetIterator()
    While it.%GetNext(.i, .sid) {
        Continue:'$D(cand(sid))
        Continue:$D(done("c", sid))
        Set done("c", sid) = 1
        Set c = ##class(RecallReach.Data.Contact).%New()
        Set c.RecallNumber = appr.RecallNumber, c.SubjectId = sid, c.P = cand(sid).p, c.ApprovalId = appr.%Id(), c.CreatedAt = ##class(RecallReach.Core.Config).Now()
        Set c.Reason = $S(cand(sid).exact&&(cand(sid).p>=1): "Lot confirmed by barcode", 1: "Estimated about "_$FN(cand(sid).p*100,"",0)_"% chance of a recalled unit")
        Do c.%Save()
        Set contacts = contacts + 1
    }
    Set appr.HoldCount = holds, appr.ContactCount = contacts
    Do appr.%Save()
    Set rec.Status = "approved"
    Do rec.%Save()
    Set resp.Holds = holds, resp.Contacts = contacts
    Do ##class(RecallReach.Data.Audit).Log("ActionExecutor", "actions.executed", appr.RecallNumber, holds_" next fills flagged, "_contacts_" patients on the contact list", ..%SessionId,
        "Done: "_holds_" next fill"_$S(holds=1:"", 1:"s")_" flagged to be filled from a non-recalled lot, "_contacts_" patient"_$S(contacts=1:"", 1:"s")_" on the call list")
    Quit $$$OK
}

XData MessageMap
{
<MapItems>
  <MapItem MessageType="RecallReach.Msg.ActionRequest"><Method>Execute</Method></MapItem>
</MapItems>
}

}
