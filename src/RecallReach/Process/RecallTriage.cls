/// Recall arrives -> AI Hub agent reads it and decides -> patients ranked.
Class RecallReach.Process.RecallTriage Extends Ens.BusinessProcessBPL
{

XData BPL [ XMLNamespace = "http://www.intersystems.com/bpl" ]
{
<process language='objectscript' request='RecallReach.Msg.RecallArrived' response='Ens.Response' height='1200' width='1000' >
<context>
<property name='Action' type='%String' instantiate='0' />
<property name='Shown' type='%Integer' instantiate='0' />
<property name='Hidden' type='%Integer' instantiate='0' />
</context>
<sequence xend='200' yend='1000' >
<scope name='Triage' xpos='200' ypos='150' xend='200' yend='900' >
<code name='Mark reading' xpos='200' ypos='250' >
<![CDATA[ do ##class(RecallReach.Core.Flow).SetStatus(request.RecallNumber, "reading", process.%SessionId)]]>
</code>
<call name='AI Hub agent reads recall' target='RecallReaderAgent' async='0' xpos='200' ypos='350' >
<annotation>The agent extracts the recalled product with evidence and decides the pharmacy action.</annotation>
<request type='RecallReach.Msg.AgentRequest' >
<assign property="callrequest.RecallNumber" value="request.RecallNumber" action="set" />
<assign property="callrequest.SystemPrompt" value="##class(RecallReach.Core.Py).SystemPrompt()" action="set" />
<assign property="callrequest.UserPrompt" value="##class(RecallReach.Core.Flow).UserPrompt(request.RecallNumber)" action="set" />
</request>
<response type='RecallReach.Msg.AgentResponse' >
<assign property="context.Action" value="callresponse.Action" action="set" />
</response>
</call>
<if name='Agent says no action?' condition='context.Action="no_action"' xpos='200' ypos='450' xend='200' yend='800' >
<true>
<code name='Close: no action' xpos='335' ypos='600' >
<![CDATA[ do ##class(RecallReach.Core.Flow).SetStatus(request.RecallNumber, "no_patients", process.%SessionId)]]>
</code>
</true>
<false>
<call name='Rank patients' target='PatientMatcher' async='0' xpos='65' ypos='600' >
<request type='RecallReach.Msg.MatchRequest' >
<assign property="callrequest.RecallNumber" value="request.RecallNumber" action="set" />
</request>
<response type='RecallReach.Msg.MatchResponse' >
<assign property="context.Shown" value="callresponse.Shown" action="set" />
<assign property="context.Hidden" value="callresponse.Hidden" action="set" />
</response>
</call>
<code name='Ready for pharmacist' xpos='65' ypos='700' >
<![CDATA[ do ##class(RecallReach.Core.Flow).SetStatus(request.RecallNumber, $S((context.Shown+context.Hidden)>0:"ready", 1:"no_patients"), process.%SessionId)]]>
</code>
</false>
</if>
<faulthandlers>
<catchall name='Any error' xpos='200' ypos='900' >
<code name='Record error' >
<![CDATA[ do ##class(RecallReach.Core.Flow).Fail(request.RecallNumber, context.%LastError, process.%SessionId)]]>
</code>
</catchall>
</faulthandlers>
</scope>
</sequence>
</process>
}

}
