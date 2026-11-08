/// AI Hub audit policy: every tool call the agent makes is written to the RecallReach audit trail.
Class RecallReach.AI.ToolAudit Extends %AI.Policy.Audit
{

Method %LogExecution(call As %DynamicObject, metadata As %DynamicObject, result As %DynamicObject, duration As %Integer, status As %Status) As %Status
{
    Try {
        Set c = $S($ISOBJECT(call):call.%ToJSON(), 1:call)
        Set r = $S($ISOBJECT(result):result.%ToJSON(), 1:result)
        // one readable sentence: LookupDispensed(ingredient; NDCs) -> fills / patients
        Set sum = ""
        Try {
            Set co = $S($ISOBJECT(call):call, 1:{}.%FromJSON(call))
            Set args = co.arguments
            If '$ISOBJECT(args) && (args '= "") Set args = {}.%FromJSON(args)
            Set res = $S($ISOBJECT(result):result, 1:{}.%FromJSON(result))
            If '$ISOBJECT(res."result_json") && (res."result_json" '= "") Set res = {}.%FromJSON(res."result_json")
            Set f = 0, p = 0
            If $ISOBJECT(res) && $ISOBJECT(res.ndcs) {
                Set it = res.ndcs.%GetIterator()
                While it.%GetNext(.i, .x) { Set f = f + x.fills, p = p + x.patients }
            }
            Set name = $S(co.name'="":co.name, 1:"tool")
            Set sum = "Agent called "_name_"("_$S($ISOBJECT(args):args.ingredient_"; "_args.ndcs, 1:"")_"): "_f_" fill"_$S(f=1:"", 1:"s")_" of the recalled NDCs for "_p_" patient"_$S(p=1:"", 1:"s")
            If $ISOBJECT(res) Set sum = sum_", "_(+res."ingredient_fills")_" fill"_$S(+res."ingredient_fills"=1:"", 1:"s")_" of the ingredient"
            Set sum = sum_" ("_duration_" ms)"
        } Catch { Set sum = "" }
        Do ##class(RecallReach.Data.Audit).Log("AI Hub agent", "agent.tool_call", $G(^||RecallReach("Recall")), $E(c, 1, 700)_" -> "_$E(r, 1, 3000)_" ("_duration_" ms)", $G(^||RecallReach("Session")), sum)
    } Catch {}
    Quit $$$OK
}

Method %LogDenial(call As %DynamicObject, metadata As %DynamicObject, status As %Status) As %Status
{
    Try {
        Do ##class(RecallReach.Data.Audit).Log("AI Hub agent", "agent.tool_denied", $G(^||RecallReach("Recall")), $S($ISOBJECT(call):call.%ToJSON(), 1:call)_" : "_$SYSTEM.Status.GetErrorText(status), $G(^||RecallReach("Session")), "Tool call refused: "_$SYSTEM.Status.GetErrorText(status))
    } Catch {}
    Quit $$$OK
}

}
