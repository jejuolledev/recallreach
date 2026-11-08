/// Runtime settings, kill switch and small helpers.
Class RecallReach.Core.Config
{

Parameter DATADIR = "/opt/recallreach/data";

Parameter RECORDDIR = "/opt/recallreach/recordings";

Parameter APPROVALSECONDS = 600;

/// USD per 1M tokens for claude-haiku-5-5 (Anthropic list price, Oct 2026)
Parameter PRICEIN = 0.10;

Parameter PRICEOUT = 0.50;

ClassMethod Model() As %String
{
    Set m = $SYSTEM.Util.GetEnviron("RR_MODEL")
    Quit $S(m'="":m, 1:"claude-haiku-5-5")
}

/// live when ANTHROPIC_API_KEY is set in the container environment, replay otherwise
ClassMethod Mode() As %String
{
    Quit $S($SYSTEM.Util.GetEnviron("ANTHROPIC_API_KEY")'="":"live", 1:"replay")
}

ClassMethod SpendCap() As %Double
{
    Set c = $SYSTEM.Util.GetEnviron("RR_SPEND_CAP_USD")
    Quit $S(c'="":+c, 1:5)
}

ClassMethod Spent() As %Double
{
    Quit +$G(^RecallReach("SpendUSD"))
}

ClassMethod AddSpend(usd As %Double)
{
    Lock +^RecallReach("SpendUSD"):5
    Set ^RecallReach("SpendUSD") = +$G(^RecallReach("SpendUSD")) + usd
    Lock -^RecallReach("SpendUSD")
}

ClassMethod Threshold() As %Double
{
    Quit $G(^RecallReach("Threshold"), 0.05)
}

ClassMethod IsKilled() As %Boolean
{
    Quit +$G(^RecallReach("KillSwitch"))
}

/// Turn the kill switch on/off. On: no agent call, no action, no approval is
/// accepted, and every pending approval is cancelled.
ClassMethod SetKill(on As %Boolean, actor As %String = "pharmacist", reason As %String = "") As %Status
{
    Set ^RecallReach("KillSwitch") = ''on
    Do ##class(RecallReach.Data.Audit).Log(actor, $S(on:"killswitch.on", 1:"killswitch.off"), "", reason)
    If on {
        Set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT ID FROM RecallReach_Data.Approval WHERE Status = 'pending'")
        While rs.%Next() {
            Do ##class(RecallReach.Core.Approvals).Cancel(rs.%Get("ID"), "kill switch")
        }
    }
    Quit $$$OK
}

/// UTC now as %TimeStamp
ClassMethod Now() As %TimeStamp
{
    Quit $ZDATETIME($ZTIMESTAMP, 3, 1, 0)
}

ClassMethod AddSeconds(ts As %TimeStamp, secs As %Integer) As %TimeStamp
{
    Set h = $ZDATETIMEH(ts, 3, 1)
    Set s = $P(h, ",", 2) + secs, d = +h
    Set d = d + (s \ 86400), s = s # 86400
    Quit $ZDATETIME(d_","_s, 3, 1, 0)
}

/// seconds from a to b (b - a)
ClassMethod Diff(a As %TimeStamp, b As %TimeStamp) As %Integer
{
    Set ha = $ZDATETIMEH(a, 3, 1), hb = $ZDATETIMEH(b, 3, 1)
    Quit ((+hb - +ha) * 86400) + ($P(hb, ",", 2) - $P(ha, ",", 2))
}

ClassMethod ReadStream(s) As %String
{
    If '$ISOBJECT(s) Quit ""
    Do s.Rewind()
    Set out = ""
    While 's.AtEnd { Set out = out _ s.Read(32000) }
    Quit out
}

}
