/// An FDA drug recall (openFDA drug enforcement record) and what RecallReach did with it.
Class RecallReach.Data.Recall Extends %Persistent
{

Property RecallNumber As %String [ Required ];

Property Classification As %String;

Property Firm As %String(MAXLEN = 300);

Property ProductDescription As %String(MAXLEN = "");

Property Reason As %String(MAXLEN = "");

Property ReportDate As %String;

Property InitiationDate As %String;

/// new, reading, matching, ready, awaiting_approval, approved, rejected, expired, no_patients, stopped, error
Property Status As %String [ InitialExpression = "new" ];

Property ArrivedAt As %TimeStamp;

/// Full openFDA record. The harmonized "openfda" block is used only by the accuracy panel; the agent never sees it.
Property SourceJSON As %Stream.GlobalCharacter;

Property NoticeText As %String(MAXLEN = "");

Property ExtractionJSON As %Stream.GlobalCharacter;

/// llm, replay-recorded, rule-based
Property ExtractorSource As %String;

Property Model As %String;

Property Action As %String;

Property Rationale As %String(MAXLEN = 400);

Property LowConfidence As %Integer;

Property PatientsShown As %Integer;

Property PatientsHidden As %Integer;

Property TopSubject As %String;

Property TopP As %Double;

Property ResultJSON As %Stream.GlobalCharacter;

Property SessionId As %Integer;

Property Error As %String(MAXLEN = 1000);

Index RecallIdx On RecallNumber [ Unique ];

Index StatusIdx On Status;

}
