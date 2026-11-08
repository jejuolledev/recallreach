/// LLM call request, persisted as an Interoperability message so every prompt
/// is traceable in Visual Trace (Ideas Portal DPI-I-689).
Class RecallReach.Msg.AgentRequest Extends Ens.Request
{

Property RecallNumber As %String;

Property SystemPrompt As %String(MAXLEN = "");

Property UserPrompt As %String(MAXLEN = "");

}
