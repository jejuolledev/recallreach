/// AI Hub audit policy: every tool call the agent makes is written to the RecallReach audit trail.
Class RecallReach.AI.ToolAudit Extends %AI.Policy.Audit
{

Method %LogExecution(call As %DynamicObject, metadata As %DynamicObject, result As %DynamicObject, duration As %Integer, status As %Status) As %Status
{
    Try {
        Set c = $S($ISOBJECT(call):call.%ToJSON(), 1:call)
        Set r = $S($ISOBJECT(result):result.%ToJSON(), 1:result)
        Do ##class(RecallReach.Data.Audit).Log("AI Hub agent", "agent.tool_call", $G(^||RecallReach("Recall")), $E(c, 1, 700)_" -> "_$E(r, 1, 1200)_" ("_duration_" ms)")
    } Catch {}
    Quit $$$OK
}

Method %LogDenial(call As %DynamicObject, metadata As %DynamicObject, status As %Status) As %Status
{
    Try {
        Do ##class(RecallReach.Data.Audit).Log("AI Hub agent", "agent.tool_denied", $G(^||RecallReach("Recall")), $S($ISOBJECT(call):call.%ToJSON(), 1:call)_" : "_$SYSTEM.Status.GetErrorText(status))
    } Catch {}
    Quit $$$OK
}

}
