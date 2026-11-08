/// Append-only audit trail. Every agent decision, pharmacist decision, kill
/// switch change and executed action lands here with the Interoperability
/// session id, so each row links to Visual Trace.
Class RecallReach.Data.Audit Extends %Persistent
{

Property TS As %TimeStamp [ InitialExpression = {$ZDATETIME($ZTIMESTAMP,3,1,3)} ];

Property Actor As %String(MAXLEN = 100);

Property Event As %String(MAXLEN = 100);

Property RecallNumber As %String;

Property Detail As %String(MAXLEN = 4000);

Property SessionId As %Integer;

Index TSIdx On TS;

Index RecallIdx On RecallNumber;

ClassMethod Log(actor As %String, event As %String, recall As %String = "", detail As %String = "", session As %Integer = "") As %Status
{
    Set a = ..%New()
    Set a.Actor = actor, a.Event = event, a.RecallNumber = recall, a.Detail = $E(detail, 1, 4000), a.SessionId = session
    Quit a.%Save()
}

/// Audit rows cannot be edited or deleted through objects (append-only).
Method %OnBeforeSave(insert As %Boolean) As %Status [ Private, ServerOnly = 1 ]
{
    If 'insert Quit $$$ERROR($$$GeneralError, "audit rows are append-only")
    Quit $$$OK
}

}
