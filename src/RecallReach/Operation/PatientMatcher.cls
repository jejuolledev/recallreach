/// Business operation: candidate dispenses (exact NDC via SQL, ingredient via
/// IRIS Vector Search) ranked by estimated probability (Embedded Python).
Class RecallReach.Operation.PatientMatcher Extends Ens.BusinessOperation
{

Parameter INVOCATION = "Queue";

Method Match(req As RecallReach.Msg.MatchRequest, Output resp As RecallReach.Msg.MatchResponse) As %Status
{
    Set resp = ##class(RecallReach.Msg.MatchResponse).%New()
    Set resp.RecallNumber = req.RecallNumber
    Set rec = ##class(RecallReach.Data.Recall).RecallIdxOpen(req.RecallNumber)
    If '$ISOBJECT(rec) Quit $$$ERROR($$$GeneralError, "unknown recall")
    Set cfg = "RecallReach.Core.Config"
    Set out = ##class(RecallReach.Core.Py).Match($classmethod(cfg, "ReadStream", rec.SourceJSON), $classmethod(cfg, "ReadStream", rec.ExtractionJSON),
        ##class(RecallReach.Core.Config).#DATADIR_"/sdud_cache.json", $classmethod(cfg, "Threshold"))
    Set r = {}.%FromJSON(out)
    Do rec.ResultJSON.Clear()
    Do rec.ResultJSON.Write(out)
    Set rec.PatientsShown = r.shown.%Size(), rec.PatientsHidden = r.hidden.%Size()
    If r.shown.%Size() > 0 {
        Set rec.TopSubject = r.shown.%Get(0)."subject_id", rec.TopP = r.shown.%Get(0).p
    } Else {
        Set rec.TopSubject = "", rec.TopP = 0
    }
    $$$QuitOnError(rec.%Save())
    Set resp.Shown = rec.PatientsShown, resp.Hidden = rec.PatientsHidden, resp.TopSubject = rec.TopSubject, resp.TopP = rec.TopP, resp.ExpectedAffected = r."expected_affected"
    Do ##class(RecallReach.Data.Audit).Log("PatientMatcher", "patients.ranked", req.RecallNumber,
        rec.PatientsShown_" shown, "_rec.PatientsHidden_" low-likelihood hidden (threshold "_($classmethod(cfg, "Threshold")*100)_"%), "_r.candidates_" candidate fills", ..%SessionId,
        "Patients ranked: "_rec.PatientsShown_" likely affected, "_rec.PatientsHidden_" under "_($classmethod(cfg, "Threshold")*100)_"% hidden ("_r.candidates_" fill"_$S(r.candidates=1:"", 1:"s")_" checked)")
    Quit $$$OK
}

XData MessageMap
{
<MapItems>
  <MapItem MessageType="RecallReach.Msg.MatchRequest"><Method>Match</Method></MapItem>
</MapItems>
}

}
