/// Outbound adapter for the AI Hub agent (extends the AI Hub's own
/// EnsLib.AI.Agent.OutboundAdapter). It picks the provider at start-up:
///   live   - ANTHROPIC_API_KEY is set: Anthropic API, model from RR_MODEL (default claude-haiku-5-5)
///   replay - no key: the same "anthropic" AI Hub provider, pointed at
///            RecallReach's local replay endpoint (/recallreach/replay/v1/),
///            which returns recorded replies, or the rule-based reference reply.
/// Either way the call goes through %AI.Agent.Chat().
Class RecallReach.Adapter.AgentAdapter Extends EnsLib.AI.Agent.OutboundAdapter
{

/// Base URL of the replay endpoint (served by this same IRIS instance).
Property ReplayURL As %String(MAXLEN = 300) [ InitialExpression = "http://127.0.0.1:52773/recallreach/replay/v1/" ];

Parameter SETTINGS = "ReplayURL:Basic";

Property Mode As %String;

Method OnBeforeAgentInit(ByRef agent As %AI.Agent) As %Status [ Private ]
{
    Set sc = $$$OK
    Try {
        Set key = $SYSTEM.Util.GetEnviron("ANTHROPIC_API_KEY")
        If key '= "" {
            Set ..Mode = "live"
            Set agent.Provider = ##class(%AI.Provider).Create("anthropic", {"api_key": (key)})
        } Else {
            Set ..Mode = "replay"
            Set agent.Provider = ##class(%AI.Provider).Create("anthropic", {"api_key": "replay-mode-no-key", "base_url": (..ReplayURL)})
        }
        Kill key
        Set agent.Model = ##class(RecallReach.Core.Config).Model()
        Set agent.SystemPrompt = ##class(RecallReach.Core.Py).SystemPrompt()
    } Catch ex {
        Set sc = ex.AsStatus()
    }
    Quit sc
}

}
