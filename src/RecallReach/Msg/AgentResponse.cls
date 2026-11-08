/// LLM call response with usage and cost, persisted for tracing (DPI-I-689).
Class RecallReach.Msg.AgentResponse Extends Ens.Response
{

Property RecallNumber As %String;

/// live = Anthropic API; replay = recorded/rule-based replay server (no key)
Property Mode As %String;

/// llm, replay-recorded, rule-based
Property ExtractorSource As %String;

Property Provider As %String;

Property Model As %String;

Property RawContent As %String(MAXLEN = "");

Property InputTokens As %Integer;

Property OutputTokens As %Integer;

Property CostUSD As %Double;

Property LatencyMs As %Integer;

/// The agent's decision: hold_and_contact, stock_check, no_action
Property Action As %String;

Property Rationale As %String(MAXLEN = 400);

Property LowConfidenceFields As %Integer;

Property EvidenceNotFound As %Integer;

}
