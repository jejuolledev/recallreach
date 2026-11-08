/// Distinct drug names seen in dispensing records, with a character-trigram
/// vector for IRIS Vector Search (ingredient matching when an NDC is missing
/// or spelled differently).
Class RecallReach.Data.DrugName Extends %Persistent
{

Property Name As %String(MAXLEN = 200) [ Required ];

Property Norm As %String(MAXLEN = 200);

Property Vec As %Vector(DATATYPE = "DOUBLE", LEN = 128);

Property Uses As %Integer;

Index NameIdx On Name [ Unique ];

}
