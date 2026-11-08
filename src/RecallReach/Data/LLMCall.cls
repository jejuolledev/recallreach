/// One LLM call made by the AI Hub agent (also visible as Interoperability messages in Visual Trace).
Class RecallReach.Data.LLMCall Extends %Persistent
{

Property TS As %TimeStamp [ InitialExpression = {$ZDATETIME($ZTIMESTAMP,3,1,3)} ];

Property RecallNumber As %String;

/// live or replay
Property Mode As %String;

Property Model As %String;

Property InputTokens As %Integer;

Property OutputTokens As %Integer;

Property CostUSD As %Double;

Property LatencyMs As %Integer;

Property OK As %Boolean;

Property Error As %String(MAXLEN = 1000);

Property SessionId As %Integer;

}
