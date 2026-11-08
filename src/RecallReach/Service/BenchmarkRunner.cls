/// Business service (no adapter): sends benchmark recalls to the AI Hub agent
/// so that live accuracy runs are traced like any other LLM call.
Class RecallReach.Service.BenchmarkRunner Extends Ens.BusinessService
{

Method OnProcessInput(pInput As RecallReach.Msg.AgentRequest, Output pOutput As RecallReach.Msg.AgentResponse, ByRef pHint As %String) As %Status
{
    Quit ..SendRequestSync("RecallReaderAgent", pInput, .pOutput, 120)
}

}
