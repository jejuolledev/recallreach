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

/// new, reading, ready, awaiting_approval, approved, rejected, expired, no_patients, shelf_check, shelf_done, stopped, error
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

Property Rationale As %String(MAXLEN = 600);

Property LowConfidence As %Integer;

/// recall depth: consumer, retail or wholesale (openFDA has no depth field: stated in the notice text, or inferred by the documented rule)
Property Depth As %String;

Property DepthStated As %Boolean;

Property DepthBasis As %String(MAXLEN = 400);

/// shelf-check task (stock_check branch): lots and NDCs to pull, as JSON
Property ShelfTaskJSON As %String(MAXLEN = "");

Property ShelfDoneAt As %TimeStamp;

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
