/// One dispensing record (MIMIC-IV prescriptions row). Lot/expiry/serial are
/// empty unless a GS1 DataMatrix barcode was scanned at dispensing.
Class RecallReach.Data.Dispense Extends %Persistent
{

Property DispenseId As %Integer [ Required ];

Property SubjectId As %String [ Required ];

Property HadmId As %String;

/// MIMIC shifted timestamp (not a real date).
Property StartTime As %String;

Property Drug As %String(MAXLEN = 200);

Property DrugNorm As %String(MAXLEN = 200);

/// 11-digit NDC (5-4-2, no hyphens) or empty.
Property NDC As %String(MAXLEN = 11);

Property Strength As %String(MAXLEN = 200);

Property Form As %String(MAXLEN = 100);

Property Route As %String(MAXLEN = 50);

Property Dose As %String(MAXLEN = 100);

Property Discharge As %String(MAXLEN = 100);

Property Lot As %String(MAXLEN = 40);

Property LotExpiry As %String(MAXLEN = 10);

Property Serial As %String(MAXLEN = 40);

Property GTIN As %String(MAXLEN = 14);

Property LotCapturedAt As %TimeStamp;

Property HoldNextFill As %Boolean [ InitialExpression = 0 ];

Property HoldReason As %String(MAXLEN = 300);

Index DispIdx On DispenseId [ Unique ];

Index SubjIdx On SubjectId;

Index NDCIdx On NDC;

Index DrugNormIdx On DrugNorm;

}
