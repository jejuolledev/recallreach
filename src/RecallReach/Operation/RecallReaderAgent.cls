/// Business operation that runs the IRIS AI Hub agent (RecallReach.AI.RecallReaderAgent)
/// through RecallReach.Adapter.AgentAdapter. Request and response are persisted
/// Interoperability messages: every prompt, reply, token count, cost and latency
/// shows up in Visual Trace (Ideas Portal DPI-I-689).
Class RecallReach.Operation.RecallReaderAgent Extends Ens.BusinessOperation
{

Parameter ADAPTER = "RecallReach.Adapter.AgentAdapter";

Parameter INVOCATION = "Queue";

Method Read(req As RecallReach.Msg.AgentRequest, Output resp As RecallReach.Msg.AgentResponse) As %Status
{
    Set resp = ##class(RecallReach.Msg.AgentResponse).%New()
    Set resp.RecallNumber = req.RecallNumber
    Set cfg = "RecallReach.Core.Config"
    If $classmethod(cfg, "IsKilled") {
        Do ##class(RecallReach.Data.Audit).Log("kill switch", "agent.refused", req.RecallNumber, "agent call blocked", ..%SessionId)
        Quit $$$ERROR($$$GeneralError, "Kill switch is ON: the agent does not run")
    }
    Set mode = ..Adapter.Mode
    If (mode = "live") && ($classmethod(cfg, "Spent") >= $classmethod(cfg, "SpendCap")) {
        Do ##class(RecallReach.Data.Audit).Log("budget", "agent.refused", req.RecallNumber, "spend cap reached", ..%SessionId)
        Quit $$$ERROR($$$GeneralError, "LLM spend cap reached ($"_$classmethod(cfg, "SpendCap")_")")
    }
    Set rec = ##class(RecallReach.Data.Recall).RecallIdxOpen(req.RecallNumber)
    If '$ISOBJECT(rec) Quit $$$ERROR($$$GeneralError, "unknown recall")
    Set srcJson = $classmethod(cfg, "ReadStream", rec.SourceJSON)
    Set t0 = $ZH
    Set sc = ..Adapter.SendChat(req.UserPrompt, .llm)
    Set ms = ($ZH - t0) * 1000 \ 1
    Set call = ##class(RecallReach.Data.LLMCall).%New()
    Set call.RecallNumber = req.RecallNumber, call.Mode = mode, call.Model = ..Adapter.Agent.Model, call.LatencyMs = ms, call.SessionId = ..%SessionId
    If $$$ISERR(sc) {
        Set call.OK = 0, call.Error = $E($SYSTEM.Status.GetErrorText(sc), 1, 1000)
        Do call.%Save()
        Quit sc
    }
    Set content = llm.Content
    Set inTok = 0, outTok = 0
    If $ISOBJECT(llm.Usage) Set inTok = +llm.Usage."prompt_tokens", outTok = +llm.Usage."completion_tokens"
    Set cost = $S(mode="live": (inTok * ##class(RecallReach.Core.Config).#PRICEIN + (outTok * ##class(RecallReach.Core.Config).#PRICEOUT)) / 1000000, 1: 0)
    If mode = "live" Do $classmethod(cfg, "AddSpend", cost)
    Set call.OK = 1, call.InputTokens = inTok, call.OutputTokens = outTok, call.CostUSD = cost
    Do call.%Save()
    // source of the reply
    Set source = "llm"
    If mode = "replay" {
        Set source = "rule-based"
        Try { Set j = {}.%FromJSON(content) Set:j."_replay_source"'="" source = j."_replay_source" } Catch {}
    } Else {
        Do ..Record(req.RecallNumber, content, inTok, outTok)
    }
    Set vjson = ##class(RecallReach.Core.Py).Validate(srcJson, content)
    Set v = {}.%FromJSON(vjson)
    Set resp.Mode = mode, resp.ExtractorSource = source, resp.Provider = "anthropic", resp.Model = ..Adapter.Agent.Model
    Set resp.RawContent = content, resp.InputTokens = inTok, resp.OutputTokens = outTok, resp.CostUSD = cost, resp.LatencyMs = ms
    If v.error '= "" {
        Do ##class(RecallReach.Data.Audit).Log("AI Hub agent", "agent.invalid_reply", req.RecallNumber, v.error, ..%SessionId)
        Quit $$$ERROR($$$GeneralError, v.error)
    }
    Set resp.Action = v.action, resp.Rationale = v.rationale, resp.LowConfidenceFields = v."low_confidence", resp.EvidenceNotFound = v."evidence_not_found"
    // store on the recall only when it is being triaged (benchmark runs leave the inbox alone)
    If req.%Extends("RecallReach.Msg.AgentRequest") && (rec.Status '= "pool") {
        Do rec.ExtractionJSON.Clear()
        Do rec.ExtractionJSON.Write(vjson)
        Set rec.ExtractorSource = source, rec.Model = resp.Model, rec.Action = v.action, rec.Rationale = v.rationale, rec.LowConfidence = v."low_confidence"
        Do rec.%Save()
        Do ##class(RecallReach.Data.Audit).Log("AI Hub agent", "agent.decided", req.RecallNumber,
            "action="_v.action_"; "_v.rationale_" (source: "_source_", "_v."low_confidence"_" low-confidence fields, "_inTok_"+"_outTok_" tokens, $"_$FN(cost,"",5)_")", ..%SessionId)
    }
    Quit $$$OK
}

/// live replies are saved so they can be replayed later without a key
Method Record(recall As %String, content As %String, inTok As %Integer, outTok As %Integer)
{
    Try {
        Set dir = ##class(RecallReach.Core.Config).#RECORDDIR
        Do ##class(%File).CreateDirectoryChain(dir)
        Set f = ##class(%Stream.FileCharacter).%New()
        Set f.Filename = dir_"/"_recall_".json"
        Set o = {"recall_number": (recall), "model": (..Adapter.Agent.Model), "recorded_at": (##class(RecallReach.Core.Config).Now()), "input_tokens": (inTok), "output_tokens": (outTok), "content": (content)}
        Do f.Write(o.%ToJSON())
        Do f.%Save()
    } Catch {}
}

XData MessageMap
{
<MapItems>
  <MapItem MessageType="RecallReach.Msg.AgentRequest"><Method>Read</Method></MapItem>
</MapItems>
}

}
