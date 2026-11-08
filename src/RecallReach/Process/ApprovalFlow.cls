/// Pharmacist approval through the IRIS Workflow Engine (role "Pharmacist").
/// The plan runs only if a pharmacist approves within 10 minutes and the kill switch is off.
Class RecallReach.Process.ApprovalFlow Extends Ens.BusinessProcessBPL
{

XData BPL [ XMLNamespace = "http://www.intersystems.com/bpl" ]
{
<process language='objectscript' request='RecallReach.Msg.ApprovalRequest' response='Ens.Response' height='1400' width='1000' >
<context>
<property name='Decision' type='%String' instantiate='0' />
<property name='Killed' type='%Boolean' instantiate='0' />
<property name='Subject' type='%String' instantiate='0' />
</context>
<sequence xend='200' yend='1200' >
<assign name='Kill switch?' property='context.Killed' value='##class(RecallReach.Core.Config).IsKilled()' action='set' xpos='200' ypos='250' />
<assign name='Task subject' property='context.Subject' value='"RecallReach approval #"_request.ApprovalId' action='set' xpos='200' ypos='350' />
<if name='Stopped?' condition='context.Killed' xpos='200' ypos='450' xend='200' yend='1100' >
<true>
<code name='Cancel (kill switch)' xpos='335' ypos='600' >
<![CDATA[ do ##class(RecallReach.Core.Approvals).Cancel(request.ApprovalId, "kill switch")]]>
</code>
</true>
<false>
<call name='Ask pharmacist' target='Pharmacist' async='1' xpos='65' ypos='600' >
<annotation>IRIS Workflow task. Completed only through the RecallReach approval screen (single-use, 10-minute token).</annotation>
<request type='EnsLib.Workflow.TaskRequest' >
<assign property="callrequest.%Subject" value="context.Subject" action="set" />
<assign property="callrequest.%Message" value="request.Summary" action="set" />
<assign property="callrequest.%Actions" value='"Approve,Reject"' action="set" />
<assign property="callrequest.%Priority" value="1" action="set" />
</request>
<response type='EnsLib.Workflow.TaskResponse' >
<assign property="context.Decision" value="callresponse.%Action" action="set" />
</response>
</call>
<sync name='Wait up to 10 minutes' calls='Ask pharmacist' timeout='615' type='all' xpos='65' ypos='700' />
<if name='Timed out?' condition='synctimedout' xpos='65' ypos='800' xend='65' yend='1050' >
<true>
<code name='Expire approval' xpos='200' ypos='950' >
<![CDATA[ do ##class(RecallReach.Core.Approvals).MarkExpired(request.ApprovalId)]]>
</code>
</true>
<false>
<if name='Approved?' condition='context.Decision="Approve"' xpos='-70' ypos='950' >
<true>
<call name='Execute plan' target='ActionExecutor' async='0' >
<request type='RecallReach.Msg.ActionRequest' >
<assign property="callrequest.ApprovalId" value="request.ApprovalId" action="set" />
</request>
<response type='RecallReach.Msg.ActionResponse' />
</call>
</true>
</if>
</false>
</if>
</false>
</if>
</sequence>
</process>
}

}
