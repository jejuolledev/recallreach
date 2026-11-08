/// Custom inbound adapter: brings FDA drug recalls into the production.
///   Source = "queue"       : recalls queued by the UI ("Simulate new FDA recall") or at start-up
///   Source = "openfda-live": polls https://api.fda.gov/drug/enforcement.json for the newest reports
/// Stops taking anything in while the kill switch is on.
Class RecallReach.Adapter.RecallFeedInboundAdapter Extends Ens.InboundAdapter
{

Property Source As %String(VALUELIST = ",queue,openfda-live") [ InitialExpression = "queue" ];

Property LiveURL As %String(MAXLEN = 300) [ InitialExpression = "https://api.fda.gov/drug/enforcement.json?sort=report_date:desc&limit=5" ];

Property SSLConfig As %String [ InitialExpression = "RecallReachSSL" ];

Parameter SETTINGS = "Source:Basic,LiveURL:Basic,SSLConfig:Connection";

Method OnTask() As %Status
{
    Set sc = $$$OK
    If ##class(RecallReach.Core.Config).IsKilled() Quit $$$OK
    Try {
        If ..Source = "openfda-live" {
            Set sc = ..PollLive()
        }
        // queue is always drained (the UI uses it in both modes)
        Set k = ""
        For {
            Set k = $O(^RecallReach("Inbox", k), 1, rn)
            Quit:k=""
            Kill ^RecallReach("Inbox", k)
            Set sc = ..BusinessHost.ProcessInput(##class(Ens.StringContainer).%New(rn))
            Quit:$$$ISERR(sc)
        }
    } Catch ex {
        Set sc = ex.AsStatus()
    }
    Quit sc
}

Method PollLive() As %Status
{
    Set sc = $$$OK
    Try {
        Set req = ##class(%Net.HttpRequest).%New()
        Set req.Server = "api.fda.gov", req.Https = 1, req.SSLConfiguration = ..SSLConfig, req.Timeout = 20
        Set path = $P(..LiveURL, "api.fda.gov", 2)
        $$$ThrowOnError(req.Get(path))
        Set body = {}.%FromJSON(req.HttpResponse.Data)
        Set it = body.results.%GetIterator()
        While it.%GetNext(.i, .rec) {
            If rec."product_type" '= "Drugs" Continue
            Set rn = rec."recall_number"
            If ##class(RecallReach.Data.Recall).RecallIdxExists(rn) Continue
            $$$ThrowOnError(##class(RecallReach.Core.Setup).AddRecall(rec, "new"))
            Set ^RecallReach("Inbox", $I(^RecallReach("InboxSeq"))) = rn
        }
    } Catch ex {
        Set sc = ex.AsStatus()
        $$$LOGWARNING("openFDA live poll failed: "_$SYSTEM.Status.GetErrorText(sc))
        Set sc = $$$OK
    }
    Quit sc
}

}
