/// AI Hub authorization policy: while the RecallReach kill switch is on, the
/// agent may not execute any tool.
Class RecallReach.AI.KillSwitchPolicy Extends %AI.Policy.Authorization
{

Method %CanExecute(toolref As %String, call As %DynamicObject, metadata As %DynamicObject) As %Status
{
    If ##class(RecallReach.Core.Config).IsKilled() Quit $$$ERROR($$$GeneralError, "RecallReach kill switch is ON")
    Quit $$$OK
}

}
