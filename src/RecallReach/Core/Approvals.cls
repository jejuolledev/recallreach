/// Pharmacist approvals: a random token shown once (only its SHA-256 is stored),
/// valid for 10 minutes, usable exactly once. Approve/Reject completes the IRIS
/// Workflow task that the ApprovalFlow business process is waiting on.
Class RecallReach.Core.Approvals
{

ClassMethod Hash(token As %String) As %String
{
    Quit $ZCONVERT(##class(%xsd.hexBinary).LogicalToXSD($SYSTEM.Encryption.SHAHash(256, token)), "L")
}

ClassMethod NewToken() As %String
{
    Quit $ZCONVERT(##class(%xsd.hexBinary).LogicalToXSD($SYSTEM.Encryption.GenCryptRand(24)), "L")
}

/// Validate the plan against the ranked list and create the approval.
/// plan = {"hold":[subject ids], "contact":[subject ids]}
ClassMethod Create(recallNumber As %String, plan As %DynamicObject, Output token As %String, Output approvalId As %Integer, Output err As %String) As %Status
{
    Set token = "", approvalId = "", err = ""
    If ##class(RecallReach.Core.Config).IsKilled() Set err = "Kill switch is ON" Quit $$$OK
    Set rec = ##class(RecallReach.Data.Recall).RecallIdxOpen(recallNumber)
    If '$ISOBJECT(rec) Set err = "unknown recall" Quit $$$OK
    If (rec.Status '= "ready") && (rec.Status '= "rejected") && (rec.Status '= "expired") && (rec.Status '= "stopped") Set err = "recall is "_rec.Status Quit $$$OK
    If rec.Action '= "hold_and_contact" Set err = "This recall is a shelf check ("_rec.Depth_" level): no patient plan is needed." Quit $$$OK
    Set result = {}.%FromJSON(##class(RecallReach.Core.Config).ReadStream(rec.ResultJSON))
    For list = result.shown, result.hidden {
        Set it = list.%GetIterator()
        While it.%GetNext(.i, .row) { Set ok(row."subject_id") = 1 }
    }
    Set clean = {"hold": [], "contact": []}
    For key = "hold", "contact" {
        Set arr = plan.%Get(key)
        Continue:'$ISOBJECT(arr)
        Set it = arr.%GetIterator()
        Kill seen
        While it.%GetNext(.i, .sid) {
            If '$D(ok(sid)) Set err = "patient "_sid_" is not on this recall's list" Return $$$OK
            Continue:$D(seen(sid))
            Set seen(sid) = 1
            Do clean.%Get(key).%Push(sid)
        }
    }
    If (clean.hold.%Size() + clean.contact.%Size()) = 0 Set err = "nothing selected" Quit $$$OK
    // one open approval per recall
    &sql(UPDATE RecallReach_Data.Approval SET Status = 'cancelled' WHERE RecallNumber = :recallNumber AND Status = 'pending')
    Set token = ..NewToken()
    Set a = ##class(RecallReach.Data.Approval).%New()
    Set a.TokenHash = ..Hash(token), a.RecallNumber = recallNumber, a.ActionsJSON = clean.%ToJSON()
    Set a.CreatedAt = ##class(RecallReach.Core.Config).Now()
    Set a.ExpiresAt = ##class(RecallReach.Core.Config).AddSeconds(a.CreatedAt, ##class(RecallReach.Core.Config).#APPROVALSECONDS)
    $$$QuitOnError(a.%Save())
    Set approvalId = a.%Id()
    Set a.TaskSubject = "RecallReach approval #"_approvalId
    $$$QuitOnError(a.%Save())
    Set rec.Status = "awaiting_approval"
    Do rec.%Save()
    // the audit row is written by Dispatch, once the Interoperability session exists
    Quit $$$OK
}

/// Start the ApprovalFlow business process for an approval (via the ApprovalIntake service).
ClassMethod Dispatch(approvalId As %Integer) As %Status
{
    Set a = ##class(RecallReach.Data.Approval).%OpenId(approvalId)
    Set req = ##class(RecallReach.Msg.ApprovalRequest).%New()
    Set req.ApprovalId = approvalId, req.RecallNumber = a.RecallNumber
    Set p = {}.%FromJSON(a.ActionsJSON)
    Set req.Summary = "Fill next refill from a non-recalled lot: "_p.hold.%Size()_" patients. Call: "_p.contact.%Size()_" patients."
    $$$QuitOnError(##class(Ens.Director).CreateBusinessService("ApprovalIntake", .svc))
    Set sc = svc.ProcessInput(req)
    Set a = ##class(RecallReach.Data.Approval).%OpenId(approvalId)
    Do ##class(RecallReach.Data.Audit).Log("pharmacist", "approval.requested", a.RecallNumber,
        "hold "_p.hold.%Size()_", contact "_p.contact.%Size()_"; expires "_a.ExpiresAt_" UTC; single use", a.SessionId,
        "Approval requested: "_..Plan(p)_". Expires "_$E(a.ExpiresAt, 12, 16)_" UTC, works once")
    Quit sc
}

/// "2 next fills from a non-recalled lot, call 2 patients (10002428, 10015860)"
ClassMethod Plan(p As %DynamicObject) As %String
{
    Set h = p.hold.%Size(), c = p.contact.%Size(), ids = ""
    Set it = p.contact.%GetIterator()
    While it.%GetNext(.i, .sid) { Set:i<4 ids = ids_$S(ids="":"", 1:", ")_sid }
    If c > 4 Set ids = ids_", ..."
    Quit h_" next fill"_$S(h=1:"", 1:"s")_" from a non-recalled lot, call "_c_" patient"_$S(c=1:"", 1:"s")_$S(ids'="":" ("_ids_")", 1:"")
}

/// decision = "approve" | "reject". Returns {"ok":1} or {"ok":0,"code":http,"error":...}
ClassMethod Decide(token As %String, decision As %String, reason As %String = "", actor As %String = "pharmacist") As %DynamicObject
{
    Set a = ##class(RecallReach.Data.Approval).TokenIdxOpen(..Hash(token))
    If '$ISOBJECT(a) Quit {"ok": 0, "code": 404, "error": "This approval link is not valid."}
    If ##class(RecallReach.Core.Config).IsKilled() Quit {"ok": 0, "code": 423, "error": "Kill switch is ON: nothing can be approved."}
    If (decision = "reject") && ($ZSTRIP(reason, "<>W") = "") Quit {"ok": 0, "code": 400, "error": "Please write why you reject this plan."}
    If (decision '= "approve") && (decision '= "reject") Quit {"ok": 0, "code": 400, "error": "unknown decision"}
    Set id = a.%Id()
    Lock +^RecallReach("Approval", id):5
    Else  Quit {"ok": 0, "code": 409, "error": "busy, try again"}
    Set out = ""
    Try {
        Set a = ##class(RecallReach.Data.Approval).%OpenId(id, 4)
        Do ..ExpireIfDue(a)
        If a.UsedAt '= "" {
            Set out = {"ok": 0, "code": 409, "error": ("This approval link was already used ("_a.Status_" at "_a.UsedAt_" UTC). Each link works once.")}
        } ElseIf a.Status = "expired" {
            Set out = {"ok": 0, "code": 410, "error": "This approval expired after 10 minutes. Ask for a new one."}
        } ElseIf a.Status '= "pending" {
            Set out = {"ok": 0, "code": 409, "error": ("This approval is "_a.Status_".")}
        } Else {
            Set a.UsedAt = ##class(RecallReach.Core.Config).Now(), a.DecidedBy = actor
            Set a.Status = $S(decision="approve":"approved", 1:"rejected")
            Set a.RejectReason = $E(reason, 1, 500)
            $$$ThrowOnError(a.%Save())
            Set out = {"ok": 1, "status": (a.Status)}
        }
    } Catch ex {
        Set out = {"ok": 0, "code": 500, "error": ($SYSTEM.Status.GetErrorText(ex.AsStatus()))}
    }
    Lock -^RecallReach("Approval", id)
    If out.ok {
        Do ##class(RecallReach.Data.Audit).Log(actor, "approval."_a.Status, a.RecallNumber, $S(decision="reject":"reason: "_reason, 1:a.ActionsJSON), a.SessionId,
            $S(decision="reject":"Rejected by the pharmacist. Reason: "_reason, 1:"Approved by the pharmacist: "_..Plan({}.%FromJSON(a.ActionsJSON))))
        Set sc = ..CompleteTask(a, $S(decision="approve":"Approve", 1:"Reject"))
        If $$$ISERR(sc) Set out.warning = $SYSTEM.Status.GetErrorText(sc)
        If decision = "reject" {
            Set rec = ##class(RecallReach.Data.Recall).RecallIdxOpen(a.RecallNumber)
            Set rec.Status = "rejected" Do rec.%Save()
        }
    }
    Quit out
}

ClassMethod ExpireIfDue(a As RecallReach.Data.Approval)
{
    If (a.Status = "pending") && (##class(RecallReach.Core.Config).Diff(a.ExpiresAt, ##class(RecallReach.Core.Config).Now()) >= 0) {
        Set a.Status = "expired"
        Do a.%Save()
        Do ##class(RecallReach.Data.Audit).Log("timer", "approval.expired", a.RecallNumber, "not decided within 10 minutes", a.SessionId, "Approval expired: nobody decided within 10 minutes, nothing was done")
        Set rec = ##class(RecallReach.Data.Recall).RecallIdxOpen(a.RecallNumber)
        If $ISOBJECT(rec) && (rec.Status = "awaiting_approval") Set rec.Status = "expired" Do rec.%Save()
    }
}

/// called by ApprovalFlow when the Workflow wait times out
ClassMethod MarkExpired(approvalId As %Integer) As %Status
{
    Set a = ##class(RecallReach.Data.Approval).%OpenId(approvalId)
    Quit:'$ISOBJECT(a) $$$OK
    If a.Status = "pending" {
        Set a.ExpiresAt = ##class(RecallReach.Core.Config).Now()
        Do ..ExpireIfDue(a)
    }
    Quit $$$OK
}

ClassMethod Cancel(approvalId As %Integer, why As %String) As %Status
{
    Set a = ##class(RecallReach.Data.Approval).%OpenId(approvalId)
    Quit:'$ISOBJECT(a) $$$OK
    Quit:a.Status'="pending" $$$OK
    Set a.Status = "cancelled", a.RejectReason = why
    Do a.%Save()
    Do ##class(RecallReach.Data.Audit).Log("system", "approval.cancelled", a.RecallNumber, why, a.SessionId, "Approval cancelled ("_why_"): nothing was done")
    Set rec = ##class(RecallReach.Data.Recall).RecallIdxOpen(a.RecallNumber)
    If $ISOBJECT(rec) && (rec.Status = "awaiting_approval") Set rec.Status = "stopped" Do rec.%Save()
    Quit ..CompleteTask(a, "")
}

/// Find the open Workflow task for this approval and complete it.
ClassMethod CompleteTask(a As RecallReach.Data.Approval, action As %String) As %Status
{
    If $G(^RecallReach("UnitTest")) Quit $$$OK
    Set subj = a.TaskSubject, tid = ""
    For try = 1:1:25 {
        Set rs = ##class(%SQL.Statement).%ExecDirect(, "SELECT ID FROM EnsLib_Workflow.TaskResponse WHERE %Subject = ? AND TaskStatus_IsComplete = 0", subj)
        If rs.%Next() Set tid = rs.%Get("ID") Quit
        Hang 0.2
    }
    If tid = "" Quit $$$ERROR($$$GeneralError, "workflow task not found for "_subj)
    Set task = ##class(EnsLib.Workflow.TaskResponse).%OpenId(tid)
    Quit task.CompleteTask(action)
}

ClassMethod ToJSON(a As RecallReach.Data.Approval) As %DynamicObject
{
    Do ..ExpireIfDue(a)
    Set now = ##class(RecallReach.Core.Config).Now()
    Set left = ##class(RecallReach.Core.Config).Diff(now, a.ExpiresAt)
    Quit {"id": (a.%Id()), "recall_number": (a.RecallNumber), "status": (a.Status), "created_at": (a.CreatedAt), "expires_at": (a.ExpiresAt),
          "seconds_left": ($S(left>0:left, 1:0)), "used_at": (a.UsedAt), "decided_by": (a.DecidedBy), "reject_reason": (a.RejectReason),
          "plan": ({}.%FromJSON(a.ActionsJSON)), "holds": (a.HoldCount), "contacts": (a.ContactCount), "session_id": (a.SessionId)}
}

}
