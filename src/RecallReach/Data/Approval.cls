/// A pharmacist approval request. The token is shown once; only its SHA-256
/// is stored. Expires 10 minutes after creation and can be used once.
Class RecallReach.Data.Approval Extends %Persistent
{

Property TokenHash As %String(MAXLEN = 64) [ Required ];

Property RecallNumber As %String [ Required ];

Property ActionsJSON As %String(MAXLEN = "");

Property CreatedAt As %TimeStamp;

Property ExpiresAt As %TimeStamp;

/// pending, approved, rejected, expired, cancelled
Property Status As %String [ InitialExpression = "pending" ];

Property UsedAt As %TimeStamp;

Property DecidedBy As %String;

Property RejectReason As %String(MAXLEN = 500);

Property TaskSubject As %String(MAXLEN = 100);

Property SessionId As %Integer;

Property HoldCount As %Integer;

Property ContactCount As %Integer;

Index TokenIdx On TokenHash [ Unique ];

Index RecallIdx On RecallNumber;

}
