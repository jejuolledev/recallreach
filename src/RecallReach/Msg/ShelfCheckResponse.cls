Class RecallReach.Msg.ShelfCheckResponse Extends Ens.Response
{

Property RecallNumber As %String;

/// lots to pull, e.g. "131928 (exp 2015-09-30)"
Property Lots As %String(MAXLEN = 2000);

Property NDCs As %String(MAXLEN = 2000);

}
