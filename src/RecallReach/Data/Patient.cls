/// A de-identified patient from the MIMIC-IV Clinical Database Demo (v2.2).
/// No names: the UI shows the MIMIC subject_id only.
Class RecallReach.Data.Patient Extends %Persistent
{

Property SubjectId As %String [ Required ];

Property Gender As %String(MAXLEN = 1);

Property AnchorAge As %Integer;

/// Shifted year that corresponds to some real year inside AnchorYearGroup.
Property AnchorYear As %Integer;

/// Real 3-year window, e.g. "2014-2016".
Property AnchorYearGroup As %String;

Index SubjectIdx On SubjectId [ Unique ];

}
