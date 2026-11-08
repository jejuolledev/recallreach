/// IRIS AI Hub agent that reads one FDA recall notice and decides
/// (1) which exact product is recalled, with verbatim evidence, and
/// (2) what the pharmacy should do (hold_and_contact / stock_check / no_action).
/// The system prompt lives in recallreach_core/extract.py (single source of truth).
Class RecallReach.AI.RecallReaderAgent Extends %AI.Agent
{

Parameter PROVIDER = "anthropic";

Parameter MODEL = "claude-haiku-5-5";

}
