/// Business service (no adapter) used by the REST API to start an ApprovalFlow session.
Class RecallReach.Service.ApprovalIntake Extends Ens.BusinessService
{

Method OnProcessInput(pInput As RecallReach.Msg.ApprovalRequest, Output pOutput As %RegisteredObject, ByRef pHint As %String) As %Status
{
    // the session id exists only after the first message is sent
    Set sc = ..SendRequestAsync("ApprovalFlow", pInput)
    Set appr = ##class(RecallReach.Data.Approval).%OpenId(pInput.ApprovalId)
    If $ISOBJECT(appr) Set appr.SessionId = ..%SessionId Do appr.%Save()
    Quit sc
}

}
