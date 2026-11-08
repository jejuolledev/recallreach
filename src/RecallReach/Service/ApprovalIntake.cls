/// Business service (no adapter) used by the REST API to start an ApprovalFlow session.
Class RecallReach.Service.ApprovalIntake Extends Ens.BusinessService
{

Method OnProcessInput(pInput As RecallReach.Msg.ApprovalRequest, Output pOutput As %RegisteredObject, ByRef pHint As %String) As %Status
{
    Set appr = ##class(RecallReach.Data.Approval).%OpenId(pInput.ApprovalId)
    If $ISOBJECT(appr) Set appr.SessionId = ..%SessionId Do appr.%Save()
    Quit ..SendRequestAsync("ApprovalFlow", pInput)
}

}
