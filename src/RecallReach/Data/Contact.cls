/// A patient on the pharmacist-approved contact list.
Class RecallReach.Data.Contact Extends %Persistent
{

Property RecallNumber As %String;

Property SubjectId As %String;

Property P As %Double;

Property Reason As %String(MAXLEN = 400);

Property ApprovalId As %Integer;

Property CreatedAt As %TimeStamp;

Property Status As %String [ InitialExpression = "to call" ];

Index RecallIdx On RecallNumber;

}
