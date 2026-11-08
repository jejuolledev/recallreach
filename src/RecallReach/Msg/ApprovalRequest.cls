/// Pharmacist approval of an action plan (hold next fill + contact list).
Class RecallReach.Msg.ApprovalRequest Extends Ens.Request
{

Property ApprovalId As %Integer;

Property RecallNumber As %String;

Property Summary As %String(MAXLEN = 2000);

}
