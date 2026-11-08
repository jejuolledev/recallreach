/// Local stand-in for the Anthropic Messages API, used when no API key is set.
/// The AI Hub "anthropic" provider is pointed here (base_url), so the agent runs
/// through exactly the same %AI.Agent code path. Reply = recorded live reply for
/// that recall if one exists, otherwise the deterministic rule-based extractor.
/// Accepts calls from this container only.
Class RecallReach.API.Replay Extends %CSP.REST
{

Parameter CONTENTTYPE = "application/json";

Parameter CHARSET = "utf-8";

XData UrlMap [ XMLNamespace = "http://www.intersystems.com/urlmap" ]
{
<Routes>
  <Route Url="/v1/messages" Method="POST" Call="Messages" />
  <Route Url="/v1/models/:id" Method="GET" Call="Model" />
</Routes>
}

ClassMethod Local() As %Boolean
{
    Set ip = %request.CgiEnvs("REMOTE_ADDR")
    Quit (ip = "127.0.0.1") || (ip = "::1") || (ip = "::ffff:127.0.0.1")
}

ClassMethod Model(id As %String) As %Status
{
    If '..Local() Set %response.Status = 403 Quit $$$OK
    Write {"id": (id), "type": "model", "display_name": (id_" (RecallReach replay)")}.%ToJSON()
    Quit $$$OK
}

ClassMethod Messages() As %Status
{
    If '..Local() Set %response.Status = 403 Write {"type":"error","error":{"type":"permission_error","message":"replay endpoint is local only"}}.%ToJSON() Quit $$$OK
    Set body = {}.%FromJSON(%request.Content)
    Set text = "", toolResult = "", toolResultSeen = 0
    Set it = body.messages.%GetIterator()
    While it.%GetNext(.i, .m) {
        If m.role '= "user" Continue
        If $ISOBJECT(m.content) {
            Set ic = m.content.%GetIterator()
            While ic.%GetNext(.j, .part) {
                If part.type = "text" Set text = text_part.text
                If part.type = "tool_result" {
                    Set toolResultSeen = 1
                    If $ISOBJECT(part.content) {
                        Set ir = part.content.%GetIterator()
                        While ir.%GetNext(.k, .c) { Set:c.type="text" toolResult = toolResult_c.text }
                    } Else {
                        Set toolResult = toolResult_part.content
                    }
                }
            }
        } Else {
            Set text = text_m.content
        }
    }
    Set rn = $P($P(text, "Recall number: ", 2), $C(10))
    Set r = ##class(RecallReach.Data.Recall).RecallIdxOpen(rn)
    If '$ISOBJECT(r) {
        Set %response.Status = 400
        Write {"type":"error","error":{"type":"invalid_request_error","message":"replay: unknown recall"}}.%ToJSON()
        Quit $$$OK
    }
    Set src = ##class(RecallReach.Core.Config).ReadStream(r.SourceJSON)
    // step 1: like the live model, call the pharmacy tool first (when the agent offers it)
    Set toolName = ""
    If 'toolResultSeen && $ISOBJECT(body.tools) {
        Set it = body.tools.%GetIterator()
        While it.%GetNext(.i, .t) { Set:$ZCVT(t.name,"L")["lookupdispensed" toolName = t.name }
    }
    If toolName '= "" {
        Set args = {}.%FromJSON(##class(RecallReach.Core.Py).ReferenceToolArgs(src))
        Set out = {"id": ("msg_replay_"_$TR($ZTIMESTAMP, ",.", "")), "type": "message", "role": "assistant", "model": (body.model),
            "content": [{"type": "text", "text": "Checking this pharmacy's dispensing records first."}, {"type": "tool_use", "id": ("toolu_replay_"_$R(1000000)), "name": (toolName), "input": (args)}],
            "stop_reason": "tool_use", "stop_sequence": null, "usage": {"input_tokens": ($L(text) \ 4), "output_tokens": 40}}
        Write out.%ToJSON()
        Quit $$$OK
    }
    // step 2: final answer - recorded live reply if we have one, else the rule-based reference
    Set content = "", file = ##class(RecallReach.Core.Config).#RECORDDIR_"/"_rn_".json"
    If ##class(%File).Exists(file) {
        Try {
            Set rec = {}.%FromJSONFile(file)
            Set obj = {}.%FromJSON(##class(RecallReach.Core.Py).StripFences(rec.content))
            Set obj."_replay_source" = "replay-recorded"
            Set content = obj.%ToJSON()
        } Catch { Set content = "" }
    }
    If content = "" {
        Set obj = {}.%FromJSON(##class(RecallReach.Core.Py).ReferenceReply(src, toolResult))
        Set obj."_replay_source" = "rule-based"
        Set content = obj.%ToJSON()
    }
    Set out = {"id": ("msg_replay_"_$TR($ZTIMESTAMP, ",.", "")), "type": "message", "role": "assistant", "model": (body.model),
        "content": [{"type": "text", "text": (content)}], "stop_reason": "end_turn", "stop_sequence": null,
        "usage": {"input_tokens": ($L(text) \ 4 + ($L(toolResult) \ 4)), "output_tokens": ($L(content) \ 4)}}
    Write out.%ToJSON()
    Quit $$$OK
}

}
