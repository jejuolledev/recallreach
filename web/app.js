/* RecallReach UI - plain JS, no build step. Talks to /recallreach/api (IRIS REST). */
(function () {
  "use strict";
  var API = "/recallreach/api";
  var app = document.getElementById("app");
  var state = { status: null, seen: {}, poll: null, newest: null };

  // ------------------------------------------------------------ helpers
  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function api(path, opt) {
    opt = opt || {};
    return fetch(API + path, {
      method: opt.method || "GET",
      headers: { "Content-Type": "application/json" },
      body: opt.body ? JSON.stringify(opt.body) : undefined,
    }).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (j) {
        if (!r.ok) { var e = new Error(j.error || ("HTTP " + r.status)); e.code = r.status; throw e; }
        return j;
      });
    });
  }
  function toast(msg) {
    document.querySelectorAll(".toast").forEach(function (o) { o.remove(); });
    var t = document.createElement("div"); t.className = "toast"; t.textContent = msg; t.title = "click to close";
    t.onclick = function () { t.remove(); };
    document.body.appendChild(t); setTimeout(function () { t.remove(); }, 3000);
  }
  function plural(n, one, many) { return n + " " + (n === 1 ? one : (many || one + "s")); }
  // estimates are rounded (5% steps above 10%) so they do not look more precise than they are
  function pct(p, exact) {
    if (p == null) return "-";
    if (exact) return p >= 1 ? "100%" : "0%";
    if (p <= 0) return "0%";
    if (p < 0.01) return "<1%";
    var v = p * 100;
    v = v >= 10 ? Math.round(v / 5) * 5 : Math.round(v);
    return "≈" + Math.min(v, 99) + "%";
  }
  // one NDC format everywhere: FDA 11-digit 5-4-2 with dashes (68084-0060-01)
  function to11(raw) {
    var s = String(raw || "").trim(), p = s.split("-");
    if (p.length === 3 && p.every(function (x) { return /^\d+$/.test(x); })) {
      var k = p[0].length + "-" + p[1].length + "-" + p[2].length;
      if (k === "4-4-2") return "0" + p.join("");
      if (k === "5-3-2") return p[0] + "0" + p[1] + p[2];
      if (k === "5-4-1") return p[0] + p[1] + "0" + p[2];
      if (k === "5-4-2") return p.join("");
      return "";
    }
    return /^\d{11}$/.test(s) ? s : "";
  }
  function ndc(raw) {
    var n = to11(raw);
    return n ? n.slice(0, 5) + "-" + n.slice(5, 9) + "-" + n.slice(9) : String(raw || "");
  }
  function clsPill(c) {
    var k = c === "Class I" ? "c1" : c === "Class II" ? "c2" : "c3";
    return '<span class="pill ' + k + '">' + esc(c || "Unclassified") + "</span>";
  }
  var STATUS = {
    "new": ["Just arrived", "blue"], reading: ["AI agent reading", "blue"], ready: ["Ready for pharmacist", "warn"],
    awaiting_approval: ["Waiting for approval", "warn"], approved: ["Done: approved", "ok"], rejected: ["Rejected", "bad"],
    expired: ["Approval expired", "bad"], no_patients: ["Not dispensed here", ""], stopped: ["Stopped", "bad"], error: ["Error", "bad"],
    shelf_check: ["Shelf check to do", "warn"], shelf_done: ["Shelf check done", "ok"],
  };
  function statusPill(s) { var x = STATUS[s] || [s, ""]; return '<span class="pill ' + x[1] + '">' + esc(x[0]) + "</span>"; }
  function shortName(desc) {
    var s = String(desc || "").split(/,|;| packaged| in a\)/i)[0];
    return s.length > 80 ? s.slice(0, 78) + "..." : s;
  }
  function ago(ts, now) {
    if (!ts) return "";
    var a = new Date(ts.replace(" ", "T") + "Z"), b = now ? new Date(now.replace(" ", "T") + "Z") : new Date();
    var s = Math.max(0, Math.round((b - a) / 1000));
    if (s < 60) return "just now";
    if (s < 3600) return Math.round(s / 60) + " min ago";
    if (s < 86400) return Math.round(s / 3600) + " h ago";
    return Math.round(s / 86400) + " d ago";
  }
  function fdaDate(d) { return d && d.length === 8 ? d.slice(0, 4) + "-" + d.slice(4, 6) + "-" + d.slice(6) : d || ""; }
  // what produced the agent's answer; in rule-based replay no model is called, so no model id is shown
  function sourceLabel(src, model, at) {
    if (src === "llm") return "Live reply · model " + (model || "?");
    if (src === "replay-recorded") return "Replay of recorded Claude output (" + (model || "?") + ", " + (at || "date unknown") + "), no new call";
    return "Replay (rule-based, no LLM call)";
  }
  function depthLine(r) {
    if (!r.depth) return "";
    return '<b>' + esc(r.depth.charAt(0).toUpperCase() + r.depth.slice(1)) + " level</b>";
  }
  var ACT = {
    hold_and_contact: ["Patient contact", "Consumer-level recall: find the patients who may still have it, then a pharmacist approves calls and switches their next refill to a non-recalled lot."],
    stock_check: ["Shelf check only", "The recall does not reach patients: pull the listed lots from the shelf. No patient list, no calls, no change to anyone's next refill."],
    no_action: ["No action", "This pharmacy never dispensed the product."],
  };
  function traceLink(sid, text) {
    if (!sid) return "";
    return '<a href="/csp/user/EnsPortal.VisualTrace.zen?SESSIONID=' + encodeURIComponent(sid) + '" target="_blank" rel="noopener">' + esc(text || "Visual Trace #" + sid) + "</a>";
  }
  function setTab(name) {
    document.querySelectorAll(".tabs a").forEach(function (a) { a.classList.toggle("on", a.dataset.tab === name); });
  }
  function stopPoll() { if (state.poll) { clearInterval(state.poll); state.poll = null; } }

  // ------------------------------------------------------------ sound
  var actx = null;
  function beep(freq, dur, vol, type) {
    try {
      actx = actx || new (window.AudioContext || window.webkitAudioContext)();
      var o = actx.createOscillator(), g = actx.createGain();
      o.type = type || "square"; o.frequency.value = freq;
      g.gain.setValueAtTime(vol || 0.03, actx.currentTime);
      g.gain.exponentialRampToValueAtTime(0.0001, actx.currentTime + dur);
      o.connect(g); g.connect(actx.destination); o.start(); o.stop(actx.currentTime + dur);
    } catch (e) { /* no audio */ }
  }
  function ding() { beep(1318, 0.9, 0.12, "sine"); setTimeout(function () { beep(1760, 0.7, 0.08, "sine"); }, 90); }

  // ------------------------------------------------------------ header
  function refreshStatus() {
    return api("/status").then(function (s) {
      state.status = s;
      var m = document.getElementById("mode");
      if (s.mode === "live") { m.className = "mode live"; m.textContent = "Live AI Hub agent · " + s.model; }
      else if (s.recordings) { m.className = "mode"; m.textContent = "Replay of recorded Claude outputs · " + s.recorded_at; }
      else { m.className = "mode"; m.textContent = "Replay mode · no LLM call"; }
      m.title = s.mode === "live" ? "Anthropic via IRIS AI Hub. Spent $" + (+s.spent_usd).toFixed(4) + " of $" + s.spend_cap_usd :
        "No API key: the IRIS AI Hub agent runs against the local replay endpoint, which returns the recorded " + (s.model || "") + " reply for a recall when one ships (" + (s.recordings || 0) + " do), else a rule-based reply. Set ANTHROPIC_API_KEY for live mode.";
      var k = document.getElementById("kill");
      k.classList.toggle("on", !!s.killswitch);
      document.getElementById("killbar").hidden = !s.killswitch;
      return s;
    }).catch(function () {});
  }
  document.getElementById("kill").addEventListener("click", function () {
    var on = !(state.status && state.status.killswitch);
    var reason = on ? "Stopped from the toolbar" : "Resumed from the toolbar";
    api("/killswitch", { method: "POST", body: { on: on, reason: reason } }).then(function () {
      toast(on ? "Kill switch ON: the agent and all actions are stopped." : "Kill switch OFF");
      refreshStatus().then(route);
    });
  });

  // ------------------------------------------------------------ inbox
  function viewInbox() {
    setTab("inbox");
    app.innerHTML =
      '<div class="inbox-head"><div><h1>FDA recall inbox</h1><p class="sub" style="margin:0">New FDA drug recalls show up here. An IRIS AI Hub agent reads each one and decides: call patients, check the shelf, or nothing.</p></div>' +
      '<div class="spacer"></div><button class="btn big" id="sim">Simulate new FDA recall</button></div>' +
      '<div class="list" id="list"><div class="empty">Loading...</div></div>';
    document.getElementById("sim").onclick = function () {
      var b = this; b.disabled = true;
      api("/feed/next", { method: "POST" }).then(function (j) {
        state.newest = j.queued; loadInbox(true);
      }).catch(function (e) { toast(e.message); }).then(function () { setTimeout(function () { b.disabled = false; }, 800); });
    };
    loadInbox(false);
    stopPoll(); state.poll = setInterval(function () { loadInbox(true); }, 1500);
  }
  function loadInbox(quiet) {
    api("/recalls").then(function (j) {
      var el = document.getElementById("list"); if (!el) return;
      if (!j.recalls.length) { el.innerHTML = '<div class="card empty">No recalls yet. Press <b>Simulate new FDA recall</b>.</div>'; return; }
      var html = j.recalls.map(function (r) {
        var fresh = !state.seen[r.recall_number] && quiet;
        state.seen[r.recall_number] = true;
        var busy = r.status === "new" || r.status === "reading";
        var shelf = r.action === "stock_check";
        var right = busy
          ? '<div class="count"><span class="reading">AI Hub agent is reading <span class="dots"><span></span><span></span><span></span></span></span></div>'
          : r.status === "error" || r.status === "stopped" ? '<div class="count"><div class="l">' + esc(r.error || r.status) + "</div></div>"
          : shelf ? '<div class="count"><div class="n sm">Shelf check</div><div class="l">' + esc((r.depth || "retail") + " level") + ' · no patient calls</div></div>'
          : r.action === "no_action" || r.status === "no_patients" ? '<div class="count"><div class="n sm">No action</div><div class="l">not dispensed here</div></div>'
          : '<div class="count"><div class="n">' + (r.shown || 0) + '</div><div class="l">' + (r.shown === 1 ? "patient" : "patients") + " at 5% or more</div>" +
            (r.hidden ? '<div class="h">' + r.hidden + " more under 5%</div>" : "") + "</div>";
        return '<a class="card rcard' + (fresh || (state.newest === r.recall_number && busy) ? " new" : "") + '" href="#/recall/' + encodeURIComponent(r.recall_number) + '">' +
          '<div><div class="meta">' + clsPill(r.classification) + statusPill(r.status) +
          '<span class="muted small">' + esc(r.recall_number) + " · FDA report " + esc(fdaDate(r.report_date)) + " · arrived in demo " + esc(ago(r.arrived_at, j.now)) + "</span></div>" +
          '<div class="t">' + esc(shortName(r.product)) + "</div>" +
          '<div class="why">' + esc(r.reason) + "</div></div>" + right + "</a>";
      }).join("");
      el.innerHTML = html;
    }).catch(function (e) { if (!quiet) toast(e.message); });
  }

  // ------------------------------------------------------------ recall detail
  function highlight(text, fields) {
    var spans = [];
    fields.forEach(function (f, i) { if (f.start >= 0 && f.end > f.start) spans.push({ s: f.start, e: f.end, i: i, low: f.confidence === "low" }); });
    spans.sort(function (a, b) { return a.s - b.s || b.e - a.e; });
    var out = "", pos = 0;
    spans.forEach(function (sp) {
      if (sp.s < pos) return; // overlapping: keep first
      out += esc(text.slice(pos, sp.s));
      out += '<mark class="ev' + (sp.low ? " low" : "") + '" data-f="' + sp.i + '">' + esc(text.slice(sp.s, sp.e)) + "</mark>";
      pos = sp.e;
    });
    out += esc(text.slice(pos));
    return out.replace(/^([A-Za-z /]+):/gm, '<span class="lbl">$1:</span>');
  }
  function viewRecall(rn) {
    setTab("inbox");
    app.innerHTML = '<div class="empty">Loading...</div>';
    api("/recall" + "s/" + encodeURIComponent(rn)).then(function (r) {
      var ex = r.extraction || { fields: [] };
      var busy = r.status === "new" || r.status === "reading";
      var fields = ex.fields || [];
      var A = ACT[r.action] || ["-", ""];
      var shelf = r.action === "stock_check";
      var branch = busy ? "" :
        '<div class="branch ' + (r.action || "") + '"><div class="bl"><div class="muted small">Agent decision</div><div class="a">' + esc(A[0]) + '</div>' +
        '<div class="small">' + depthLine(r) + (r.depth_basis ? ": " + esc(r.depth_basis) : "") + "</div>" +
        '<div class="small" style="margin-top:4px">' + esc(A[1]) + "</div></div>" +
        '<div class="br">' + (r.action === "hold_and_contact" && r.status !== "no_patients" ? '<button class="btn big" id="find">Find patients</button>' :
          r.status === "no_patients" ? '<span class="muted">No dispensed product matches this recall.</span>' : "") + "</div></div>";
      app.innerHTML =
        '<div class="crumbs"><a href="#/">Recalls</a> / ' + esc(rn) + "</div>" +
        '<div class="row wrap" style="margin-bottom:6px">' + clsPill(r.classification) + statusPill(r.status) + '<span class="muted small">FDA report ' + esc(fdaDate(r.report_date)) + " · initiated " + esc(fdaDate(r.initiation_date)) + "</span></div>" +
        "<h1>" + esc(shortName(r.product)) + "</h1>" +
        '<p class="sub">' + esc(r.reason) + "</p>" + branch +
        (r.depth === "consumer" && r.action && r.action !== "hold_and_contact" ? '<div class="toolchange" style="margin:-8px 0 18px"><b>The tool result changed the decision.</b> Consumer-level recall, but the LookupDispensed tool found 0 fills of the recalled NDCs in this pharmacy, so nobody is called.</div>' : "") +
        (shelf && r.shelf_task ? shelfCard(r) : "") +
        '<div class="grid2">' +
        '<div class="card"><div class="row"><h2 style="margin:0">FDA notice</h2><span class="spacer"></span><a class="small" target="_blank" rel="noopener" href="' + esc(r.fda.url) + '">Source on openFDA</a></div>' +
        '<p class="muted small" style="margin:4px 0 14px">The agent reads only this text. FDA\'s own NDC list is hidden from it (used on the Accuracy page).</p>' +
        '<div class="notice" id="notice">' + highlight(r.notice || "", fields) + "</div></div>" +
        '<div><div class="card"><div class="row"><h2 style="margin:0">What the agent read</h2><span class="spacer"></span>' +
        (ex.low_confidence ? '<span class="pill warn">' + plural(ex.low_confidence, "field") + " to check</span>" : '<span class="pill ok">All fields have evidence</span>') + "</div>" +
        '<p class="muted small" style="margin:4px 0 14px">Click a field to see its evidence in the notice. Yellow = low confidence or inferred.</p>' +
        (busy ? '<div class="reading">AI Hub agent is reading <span class="dots"><span></span><span></span><span></span></span></div>' :
          '<div class="fields" id="fields">' + fields.map(function (f, i) {
            var v = f.value || "(not stated)";
            if (f.key === "ndc" && f.value) v = ndc(f.value) + (ndc(f.value) !== f.value ? "  (printed " + f.value + ")" : "");
            if (f.key === "lot" && f.expiry) v += " · exp " + f.expiry;
            var conf = f.key === "depth" ? (f.confidence === "low" ? "inferred" : "stated") : f.confidence;
            return '<div class="field' + (f.confidence === "low" ? " low" : "") + '" data-f="' + i + '"><div class="k">' + esc(f.label) + '</div><div class="v">' + esc(v) + "</div>" +
              '<span class="pill ' + (f.confidence === "low" ? "warn" : "ok") + '">' + esc(conf) + "</span>" +
              (f.note ? '<div class="note">' + esc(f.note) + "</div>" : "") + "</div>";
          }).join("") + "</div>") +
        '<div class="decision"><div class="muted small">Why the agent decided this</div><div>' + esc(r.rationale || "") + "</div>" +
        '<div class="muted small" style="margin-top:8px">' + esc(sourceLabel(r.source, r.model, r.recorded_at)) + " · " + traceLink(r.session_id, "Open in Visual Trace") + "</div></div>" +
        "</div></div></div>";
      // linked highlights
      function hot(i, on) {
        document.querySelectorAll('[data-f="' + i + '"]').forEach(function (el) { el.classList.toggle("hot", on); });
      }
      document.querySelectorAll("[data-f]").forEach(function (el) {
        el.addEventListener("mouseenter", function () { hot(el.dataset.f, true); });
        el.addEventListener("mouseleave", function () { hot(el.dataset.f, false); });
        el.addEventListener("click", function () {
          var m = document.querySelector('#notice mark[data-f="' + el.dataset.f + '"]');
          if (m) { m.scrollIntoView({ block: "center", behavior: "smooth" }); hot(el.dataset.f, true); setTimeout(function () { hot(el.dataset.f, false); }, 1400); }
        });
      });
      var fb = document.getElementById("find");
      if (fb) fb.onclick = function () { location.hash = "#/recall/" + encodeURIComponent(rn) + "/patients?spin=1"; };
      var sd = document.getElementById("shelfdone");
      if (sd) sd.onclick = function () {
        sd.disabled = true;
        api("/recalls/" + encodeURIComponent(rn) + "/shelf-done", { method: "POST" }).then(function () { viewRecall(rn); })
          .catch(function (e) { toast(e.message); sd.disabled = false; });
      };
      if (busy) { stopPoll(); state.poll = setTimeout(function () { viewRecall(rn); }, 1500); }
    }).catch(function (e) { app.innerHTML = '<div class="card empty">' + esc(e.message) + "</div>"; });
  }

  function shelfCard(r) {
    var t = r.shelf_task || {};
    var lots = (t.lots || []).map(function (l) { return esc(l.lot) + (l.expiry ? ' <span class="muted">(exp ' + esc(l.expiry) + ")</span>" : ""); }).join(", ") || (t.all_lots ? "all lots" : "not stated in the notice");
    var done = r.status === "shelf_done";
    return '<div class="card shelf"><div class="row wrap"><h2 style="margin:0">Shelf check</h2><span class="spacer"></span>' +
      (done ? '<span class="pill ok">Done ' + esc((r.shelf_done_at || "").slice(0, 16)) + " UTC</span>" : '<button class="btn" id="shelfdone">Mark shelf check done</button>') + "</div>" +
      '<div class="shelfgrid"><div><div class="k">Lots to pull</div><div class="v mono">' + lots + '</div></div><div><div class="k">NDC</div><div class="v mono">' + esc((t.ndcs || []).join(", ") || "not stated") + "</div></div></div>" +
      "<ol>" + (t.steps || []).map(function (x) { return "<li>" + esc(x) + "</li>"; }).join("") + "</ol>" +
      '<p class="muted small" style="margin:0">' + esc(t.not_done || "") + "</p></div>";
  }

  // ------------------------------------------------------------ patients
  function windowText(row) {
    var w = (row.best && row.best.window) || [];
    if (!w[0]) return "";
    return "filled between " + w[0].slice(0, 7) + " and " + w[1].slice(0, 7);
  }
  function prow(row, i, opts) {
    opts = opts || {};
    var best = row.best || {};
    // badge colors: green = lot confirmed by barcode, blue = same NDC, amber = weaker match, gray = cleared; actions are outlined
    var badges = (row.badges || []).map(function (b) {
      var k = b === "Lot confirmed" ? "ok" : b === "Lot cleared" ? "" : b === "NDC match" ? "blue" : "warn";
      return '<span class="pill ' + k + '">' + esc(b) + "</span>";
    }).join("");
    if (row.on_hold) badges += '<span class="pill act">Next refill: other lot</span>';
    if (row.on_contact_list) badges += '<span class="pill act">On call list</span>';
    if (opts.reel) badges = "";
    var html = '<div class="prow' + (opts.top ? " top" : "") + '" data-sid="' + esc(row.subject_id) + '">' +
      '<div class="rank">' + (opts.reel && !opts.num ? "" : i + 1) + "</div>" +
      '<div><div class="who">Patient ' + esc(row.subject_id) + '</div><div class="muted small">' + esc(row.sex === "F" ? "Female" : row.sex === "M" ? "Male" : "") + (row.age ? ", " + esc(row.age) : "") + "</div>" +
      (badges ? '<div class="badges">' + badges + "</div>" : "") + "</div>" +
      '<div class="drug"><div>' + esc(row.drug) + " " + esc(row.strength || "") + '</div><div class="muted small mono">NDC ' + esc(row.ndc ? ndc(row.ndc) : "none on record") + "</div></div>" +
      '<div class="when small">' + esc(plural(row.fills, "fill")) + '<div class="muted">' + esc(windowText(row)) + "</div></div>" +
      '<div class="p">' + pct(row.p, row.exact) + "<small>" + (row.exact ? "exact (scanned lot)" : "estimate") + "</small></div>";
    if (!opts.reel) {
      var dis = opts.locked ? " disabled" : "";
      html += '<div class="acts"><label title="Fill the next refill from a lot that is not recalled (the medicine is not stopped)"><input type="checkbox" class="h" ' + (opts.checked ? "checked" : "") + dis + "> Switch next refill</label>" +
        '<label><input type="checkbox" class="c" ' + (opts.checked ? "checked" : "") + dis + "> Call patient</label>" +
        '<button class="exp">Why ' + (row.exact ? "exact" : pct(row.p)) + "?</button></div>";
      html += '<div class="detail">' + factorHtml(row) + "</div>";
    }
    return html + "</div>";
  }
  function factorHtml(row) {
    var f = (row.best && row.best.factors) || [];
    var formula = row.exact ? '<span class="fnote">A lot scanned from the barcode at dispensing decides it: exact answer, no estimate.</span>'
      : "P(fill) = " + f.map(function (x) { return x.name.toLowerCase(); }).join(" x ") +
        "<br>P(fill) = " + f.map(function (x) { return (+x.value).toFixed(2); }).join(" x ") + " = " + (+(row.best.p || 0)).toFixed(2) +
        (row.fills > 1 ? "<br>P(patient) = 1 - product(1 - P(fill)) over " + row.fills + " fills, averaged over MIMIC's one shared date shift = " + (+row.p).toFixed(2) : "") +
        '<br><span class="fnote">Shown rounded as ' + pct(row.p) + ". An estimate is capped at 99%: only a scanned lot is 100%.</span>";
    return '<div class="formula">' + formula + "</div>" + f.map(function (x) {
      return '<div class="factor"><div><b>' + esc(x.name) + '</b><div class="src">' + esc(x.source) + '</div></div><div class="fv">' + (+x.value).toFixed(2) + "</div><div>" + esc(x.why) +
        (x.caveat ? '<div class="src">' + esc(x.caveat) + "</div>" : "") + "</div></div>";
    }).join("") + (row.exact ? "" : '<p class="muted small" style="margin:8px 0 0">Estimate, not a diagnosis. Scan the lot barcode at dispensing to make this exact.</p>');
  }
  function viewPatients(rn, spin) {
    setTab("inbox");
    app.innerHTML = '<div class="empty">Loading...</div>';
    Promise.all([api("/recalls/" + encodeURIComponent(rn)), api("/recalls/" + encodeURIComponent(rn) + "/patients")]).then(function (res) {
      var r = res[0], d = res[1];
      var shown = d.shown || [], hidden = d.hidden || [];
      var locked = ["awaiting_approval", "approved"].indexOf(r.status) >= 0;
      if (r.action !== "hold_and_contact") {
        app.innerHTML = '<div class="crumbs"><a href="#/">Recalls</a> / <a href="#/recall/' + encodeURIComponent(rn) + '">' + esc(rn) + "</a> / patients</div>" +
          '<div class="card empty">' + (r.action === "stock_check" ? "This is a " + esc(r.depth || "retail") + "-level recall: the agent chose a shelf check, so no patient list is made and nobody is called. " +
          '<a href="#/recall/' + encodeURIComponent(rn) + '">See the shelf check</a>' : "No patient list for this recall.") + "</div>";
        return;
      }
      var hidNdc = hidden.filter(function (x) { return (x.badges || []).indexOf("NDC match") >= 0; }).length;
      function hbText() { return "Show " + hidden.length + " more (under " + Math.round(d.threshold * 100) + "%)" + (hidNdc ? " · " + hidNdc + " got this NDC, but filled outside the lot window" : ""); }
      var approvedAt = r.approval && r.approval.status === "approved" ? r.approval.used_at : "";
      app.innerHTML =
        '<div class="crumbs"><a href="#/">Recalls</a> / <a href="#/recall/' + encodeURIComponent(rn) + '">' + esc(rn) + "</a> / patients</div>" +
        '<div class="row">' + clsPill(r.classification) + statusPill(r.status) + "</div>" +
        "<h1>Who got " + esc(shortName(r.product)) + "?</h1>" +
        '<p class="sub">Highest estimated chance first. Patients under ' + Math.round(d.threshold * 100) + "% are hidden below the list.</p>" +
        (approvedAt ? '<div class="note-ok">Approved ' + esc(approvedAt.slice(0, 16)) + " UTC. The refills and calls below are already done; the boxes are locked.</div>" : "") +
        '<div class="stats">' +
        '<div class="card stat"><div class="n">' + shown.length + '</div><div class="l">at 5% or more (shown)</div></div>' +
        '<div class="card stat"><div class="n">' + hidden.length + '</div><div class="l">under 5% (hidden)</div></div>' +
        '<div class="card stat"><div class="n">' + (d.total || 0) + '</div><div class="l">patients with a matching fill</div></div>' +
        '<div class="card stat"><div class="n">' + (d.candidates || 0) + '</div><div class="l">fills checked<div class="muted" style="font-size:11.5px">by NDC and drug-name search</div></div></div></div>' +
        '<div id="plist"></div>' +
        (hidden.length ? '<div class="hiddenbar" id="hb" style="margin-top:8px">' + esc(hbText()) + "</div>" : "") +
        '<div id="hlist" class="plist" style="margin-top:8px"></div>' +
        (r.approval && r.approval.status === "pending" ? '<div class="sticky"><div><b>Approval pending</b> <span class="muted">' + r.approval.seconds_left + " s left</span></div><span class=\"spacer\"></span>" +
          '<span class="muted small">The approval link was shown once to the pharmacist who asked for it.</span></div>' :
          (shown.length && !locked ? '<div class="sticky"><div><b id="sumtxt"></b><div class="muted small">A pharmacist must approve. The link expires in 10 minutes and works once.</div></div><span class="spacer"></span>' +
            '<button class="btn big" id="ask">Ask pharmacist approval</button></div>' : ""));
      var pl = document.getElementById("plist");
      function render() {
        pl.className = "plist";
        pl.innerHTML = shown.map(function (row, i) { return prow(row, i, { top: i === 0, checked: !locked || row.on_hold || row.on_contact_list, locked: locked }); }).join("") ||
          '<div class="card empty">No patient is above the threshold.</div>';
        wire(pl); sum();
      }
      function wire(root) {
        root.querySelectorAll(".prow").forEach(function (el) {
          var b = el.querySelector(".exp"); if (b) b.onclick = function () { el.classList.toggle("open"); };
          el.querySelectorAll("input").forEach(function (c) { c.onchange = sum; });
        });
      }
      function sum() {
        var h = document.querySelectorAll(".prow .h:checked").length, c = document.querySelectorAll(".prow .c:checked").length;
        var t = document.getElementById("sumtxt"); if (t) t.textContent = "Switch next refill to a non-recalled lot: " + h + " · Call: " + c;
      }
      var hb = document.getElementById("hb");
      if (hb) hb.onclick = function () {
        var hl = document.getElementById("hlist");
        if (hl.innerHTML) { hl.innerHTML = ""; hb.textContent = hbText(); return; }
        hl.innerHTML = hidden.map(function (row, i) { return prow(row, shown.length + i, { checked: false, locked: locked }); }).join("");
        wire(hl); hb.textContent = "Hide the " + hidden.length + " under " + Math.round(d.threshold * 100) + "%";
      };
      var ask = document.getElementById("ask");
      if (ask) ask.onclick = function () {
        var plan = { hold: [], contact: [] };
        document.querySelectorAll(".prow").forEach(function (el) {
          var h = el.querySelector(".h"), c = el.querySelector(".c");
          if (h && h.checked) plan.hold.push(el.dataset.sid);
          if (c && c.checked) plan.contact.push(el.dataset.sid);
        });
        ask.disabled = true;
        api("/recalls/" + encodeURIComponent(rn) + "/approval", { method: "POST", body: plan }).then(function (j) {
          location.hash = "#/approve/" + j.token;
        }).catch(function (e) { toast(e.message); ask.disabled = false; });
      };
      if (spin && shown.length) spinReel(pl, shown, hidden, render); else render();
    }).catch(function (e) { app.innerHTML = '<div class="card empty">' + esc(e.message) + "</div>"; });
  }
  // the "da-da-da ... ding" moment: the reel stops with the #1 patient under the line
  function spinReel(pl, shown, hidden, done) {
    var pool = shown.concat(hidden);
    var rows = [];
    var loops = Math.max(3, Math.ceil(36 / pool.length));
    for (var k = 0; k < loops; k++) { pool.slice().sort(function () { return Math.random() - 0.5; }).forEach(function (x) { rows.push(x); }); }
    // the #1 patient must not also appear in the rows just above where the reel stops
    var n = rows.length;
    for (var e = Math.max(0, n - 3); e < n; e++) {
      if (rows[e] !== shown[0]) continue;
      for (var q = n - 4; q >= 0; q--) {
        if (rows[q] !== shown[0] && (q === 0 || rows[q - 1] !== shown[0]) && (q + 1 >= n || rows[q + 1] !== shown[0])) { rows[e] = rows[q]; rows[q] = shown[0]; break; }
      }
    }
    var target = rows.length;
    rows.push(shown[0]);
    // the rows after the stop are other patients (never the #1 again); empty spacer rows if there are none
    var others = pool.filter(function (x) { return x !== shown[0]; });
    for (var j = 0; j < 3; j++) rows.push(others[j] || null);
    pl.className = "";
    pl.innerHTML = '<div class="reelwrap" id="reelwrap"><div class="reel" id="reel">' + rows.map(function (r, i) { return r ? prow(r, i === target ? 0 : i, { reel: true, num: i === target }) : '<div class="prow" style="visibility:hidden"></div>'; }).join("") + '</div><div class="scanline" id="scanline"></div></div>';
    var wrap = document.getElementById("reelwrap"), reel = document.getElementById("reel"), line = document.getElementById("scanline");
    var items = reel.children, tEl = items[target];
    var wrapH = wrap.clientHeight, rowH = tEl.offsetHeight;
    line.style.height = (rowH + 8) + "px"; line.style.marginTop = -((rowH + 8) / 2) + "px";
    // real position of the target row inside the reel (rows are the same height in the reel, but measure anyway)
    var dist = tEl.offsetTop + rowH / 2 - wrapH / 2;
    var tops = []; for (var i = 0; i < items.length; i++) tops.push(items[i].offsetTop);
    var dur = 2200, t0 = performance.now(), lastIdx = -1;
    function ease(t) { return 1 - Math.pow(1 - t, 4); }
    function frame(now) {
      var t = Math.min(1, (now - t0) / dur), y = dist * ease(t);
      reel.style.transform = "translateY(" + (-y) + "px)";
      var mid = y + wrapH / 2, idx = 0;
      while (idx + 1 < tops.length && tops[idx + 1] <= mid) idx++;
      if (idx !== lastIdx) { lastIdx = idx; beep(700 + (idx % 5) * 40, 0.025, 0.025, "square"); }
      if (t < 1) requestAnimationFrame(frame);
      else {
        ding();
        tEl.classList.add("top", "zoom");
        wrap.dataset.landed = tEl.dataset.sid;
        setTimeout(function () { done(); var first = document.querySelector("#plist .prow"); if (first) { first.classList.add("zoom"); setTimeout(function () { first.classList.remove("zoom"); }, 900); } }, 1100);
      }
    }
    requestAnimationFrame(frame);
  }

  // ------------------------------------------------------------ approval
  function viewApproval(token) {
    setTab("inbox");
    app.innerHTML = '<div class="empty">Loading...</div>';
    api("/approvals/" + encodeURIComponent(token)).then(function (a) {
      var rn = a.recall_number, total = (state.status && state.status.approval_seconds) || 600;
      app.innerHTML =
        '<div class="approval"><div class="crumbs"><a href="#/">Recalls</a> / <a href="#/recall/' + encodeURIComponent(rn) + '">' + esc(rn) + "</a> / approval</div>" +
        "<h1>Pharmacist approval</h1><p class=\"sub\">" + esc(shortName(a.recall.product)) + " · " + esc(a.recall.classification) + "</p>" +
        '<div class="card"><div class="timer"><div class="ring"><svg width="118" height="118"><circle cx="59" cy="59" r="52" stroke="#e3e8ec" stroke-width="10" fill="none"/>' +
        '<circle id="arc" cx="59" cy="59" r="52" stroke="#0f766e" stroke-width="10" fill="none" stroke-linecap="round" stroke-dasharray="326.7" stroke-dashoffset="0"/></svg>' +
        '<div class="tl"><span id="left">--:--</span><small>left</small></div></div>' +
        '<div><div style="font-weight:700;font-size:17px">This approval works once and expires in 10 minutes.</div>' +
        '<div class="muted small">IRIS Workflow task "RecallReach approval #' + esc(a.id) + '" (role Pharmacist)' + '<span id="wfstate">' + (a.status === "pending" ? " is waiting." : " is closed.") + "</span> " + traceLink(a.session_id, "Open in Visual Trace") + "</div>" +
        '<div id="st" style="margin-top:8px">' + statusPill(a.status === "pending" ? "awaiting_approval" : a.status) + "</div></div></div>" +
        '<div class="plan"><div class="card"><div class="n">' + a.plan.hold.length + '</div><div>' + (a.plan.hold.length === 1 ? "next refill" : "next refills") + ' to fill from a non-recalled lot</div><div class="muted small">The medicine is not stopped.</div></div>' +
        '<div class="card"><div class="n">' + a.plan.contact.length + '</div><div>' + (a.plan.contact.length === 1 ? "patient" : "patients") + ' to call</div></div></div>' +
        '<div class="muted small" style="margin-bottom:6px">Patients: ' + esc(a.plan.contact.concat(a.plan.hold).filter(function (v, i, s) { return s.indexOf(v) === i; }).join(", ")) + "</div>" +
        '<div id="actions"><div class="row" style="margin-top:14px"><button class="btn big green" id="ok">Approve</button><span class="spacer"></span></div>' +
        '<div style="margin-top:16px"><textarea id="why" rows="2" placeholder="Reason, if you reject (required to reject)"></textarea>' +
        '<div class="row" style="margin-top:8px"><button class="btn ghost" id="no">Reject</button></div></div></div>' +
        '<div id="res"></div></div></div>';
      var left = a.seconds_left, timer = null;
      function tick() {
        var m = Math.floor(left / 60), s = left % 60;
        var el = document.getElementById("left"); if (!el) { clearInterval(timer); return; }
        el.textContent = m + ":" + (s < 10 ? "0" : "") + s;
        document.getElementById("arc").setAttribute("stroke-dashoffset", String(326.7 * (1 - left / total)));
        if (left <= 0) { clearInterval(timer); lock("expired"); }
        left = Math.max(0, left - 1);
      }
      function lock(why) {
        var acts = document.getElementById("actions"); if (acts) acts.style.opacity = ".4";
        document.querySelectorAll("#actions button, #actions textarea").forEach(function (b) { b.disabled = true; });
        if (why === "expired" && a.status === "pending") document.getElementById("res").innerHTML = '<div class="result bad"><b>Expired.</b> Nothing was done. Ask for a new approval from the patient list.</div>';
      }
      tick(); timer = setInterval(tick, 1000);
      function closed(t) { document.getElementById("left").textContent = t; var sm = document.querySelector(".ring .tl small"); if (sm) sm.textContent = ""; }
      if (a.status !== "pending") closed(a.status === "approved" ? "Used" : "Closed");
      if (a.status !== "pending") { clearInterval(timer); lock(); showResult(a); }
      function decide(kind) {
        var body = kind === "reject" ? { reason: document.getElementById("why").value } : {};
        api("/approvals/" + encodeURIComponent(token) + "/" + kind, { method: "POST", body: body }).then(function (j) {
          if (j && j.warning) toast("Saved. The matching IRIS Workflow task was not found: " + j.warning);
          clearInterval(timer); lock();
          closed(kind === "approve" ? "Used" : "Closed");
          setTimeout(function () { api("/approvals/" + encodeURIComponent(token)).then(showResult); }, 1200);
        }).catch(function (e) { document.getElementById("res").innerHTML = '<div class="result bad">' + esc(e.message) + "</div>"; });
      }
      document.getElementById("ok").onclick = function () { decide("approve"); };
      document.getElementById("no").onclick = function () { decide("reject"); };
      function showResult(x) {
        var st = document.getElementById("st"); if (st) st.innerHTML = statusPill(x.status === "pending" ? "awaiting_approval" : x.status);
        var wf = document.getElementById("wfstate"); if (wf && x.status !== "pending") wf.textContent = " is closed.";
        var res = document.getElementById("res"); if (!res) return;
        if (x.status === "approved") {
          res.innerHTML = '<div class="result ok"><b>Approved.</b> ' + plural(x.holds || 0, "next refill") + " will be filled from a non-recalled lot and " + plural(x.contacts || 0, "patient") + ((x.contacts || 0) === 1 ? " is" : " are") + ' on the call list. This link can\'t be used again.</div>' +
            '<div class="row wrap" style="margin-top:14px"><button class="btn ghost" id="again">Try this link again</button><a class="btn ghost" href="#/recall/' + encodeURIComponent(rn) + '/patients">See the patient list</a><a class="btn ghost" href="#/audit">Audit trail</a></div><div id="againres"></div>';
          var ag = document.getElementById("again");
          if (ag) ag.onclick = function () {
            api("/approvals/" + encodeURIComponent(token) + "/approve", { method: "POST" }).then(function () {
              document.getElementById("againres").innerHTML = '<div class="result bad">Unexpected: the link was accepted twice.</div>';
            }).catch(function (e) { document.getElementById("againres").innerHTML = '<div class="result bad"><b>Refused (HTTP ' + esc(e.code) + ").</b> " + esc(e.message) + "</div>"; });
          };
        } else if (x.status === "rejected") {
          res.innerHTML = '<div class="result bad"><b>Rejected.</b> Reason: ' + esc(x.reject_reason) + ". Nothing was executed.</div>";
        } else if (x.status === "expired") {
          res.innerHTML = '<div class="result bad"><b>Expired.</b> Nothing was done.</div>';
        } else if (x.status === "cancelled") {
          res.innerHTML = '<div class="result bad"><b>Cancelled</b> (' + esc(x.reject_reason || "") + "). Nothing was done.</div>";
        }
      }
    }).catch(function (e) { app.innerHTML = '<div class="card empty">' + esc(e.message) + "</div>"; });
  }

  // ------------------------------------------------------------ scan
  function viewScan() {
    setTab("scan");
    app.innerHTML =
      "<h1>Scan the box at dispensing</h1><p class=\"sub\">The 2D GS1 DataMatrix on a US drug package carries the product code (GTIN/NDC), lot, expiry and serial. Scan the box once when you fill it. If a later recall names that lot, the patient is matched for sure, with no estimate.</p>" +
      '<div class="card"><div class="row wrap"><h2 style="margin:0">1. Scan or paste the barcode</h2><span class="spacer"></span>' +
      '<button class="btn ghost" id="cam" hidden>Use camera</button><button class="btn ghost" id="sample">Use a sample barcode</button></div>' +
      '<p class="muted small">Scanners type the barcode like a keyboard. Both "(01)...(17)...(10)...(21)..." and raw strings with the group separator work.</p>' +
      '<textarea class="scanbox" id="raw" placeholder="(01)00316729182010(17)191130(10)PW05264(21)..."></textarea>' +
      '<div class="muted small" id="samplenote"></div>' +
      '<video id="vid" playsinline muted style="display:none;width:100%;max-width:420px;border-radius:12px;margin-top:10px"></video>' +
      '<div class="row" style="margin-top:10px"><button class="btn" id="parse">Read barcode</button></div><div id="parsed"></div></div>' +
      '<div class="card" style="margin-top:16px" id="step2" hidden><h2>2. Which fill is this box for?</h2><div id="fills"></div></div>';
    document.getElementById("sample").onclick = function () {
      api("/barcode/sample").then(function (s) {
        document.getElementById("raw").value = s.raw;
        document.getElementById("samplenote").innerHTML = "Sample: lot <b>" + esc(s.lot) + "</b> of NDC " + esc(ndc(s.ndc11)) + ", the lot named in recall " + esc(s.recall_number || "") +
          ". In the demo story this box was filled for patient " + esc(s.subject_id || "") + " (fill " + esc(s.dispense_id || "") + "). Generated by RecallReach, not a real serial.";
      });
    };
    if ("BarcodeDetector" in window) {
      var cam = document.getElementById("cam"); cam.hidden = false;
      cam.onclick = function () {
        var v = document.getElementById("vid");
        navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } }).then(function (st) {
          v.srcObject = st; v.style.display = "block"; v.play();
          var det = new window.BarcodeDetector({ formats: ["data_matrix"] });
          var iv = setInterval(function () {
            det.detect(v).then(function (codes) {
              if (codes.length) { document.getElementById("raw").value = codes[0].rawValue; clearInterval(iv); st.getTracks().forEach(function (t) { t.stop(); }); v.style.display = "none"; document.getElementById("parse").click(); }
            }).catch(function () {});
          }, 400);
        }).catch(function (e) { toast("Camera not available: " + e.message); });
      };
    }
    document.getElementById("parse").onclick = function () {
      var raw = document.getElementById("raw").value;
      api("/barcode/parse", { method: "POST", body: { raw: raw } }).then(function (p) {
        var cell = function (k, v, bad) { return '<div class="card' + (bad ? " badcell" : "") + '"><div class="k">' + k + '</div><div class="v">' + esc(v || "-") + "</div></div>"; };
        var m0 = p.matches[0];
        document.getElementById("parsed").innerHTML = '<div class="parsed">' + cell("GTIN (01)", p.gtin + (p.gtin_check_ok ? " ✓" : " check digit wrong"), !p.gtin_check_ok) +
          cell("NDC", m0 ? ndc(m0.ndc11) : (p.ndc10 || "")) + cell("Lot (10)", p.lot, !p.lot) + cell("Expiry (17)", p.expiry || "missing", !p.expiry) + cell("Serial (21)", p.serial) + "</div>" +
          (!p.gtin_check_ok ? '<div class="result bad">The GTIN check digit is wrong, so this scan may be misread. It will not be saved: scan the box again.</div>' :
            !p.expiry ? '<div class="result bad">This barcode has no expiry date (17). A lot is saved only together with its expiry.</div>' : "");
        var s2 = document.getElementById("step2"); s2.hidden = false;
        if (!p.matches.length) { document.getElementById("fills").innerHTML = '<p class="muted">No dispensing record has this NDC.</p>'; return; }
        var m = p.matches[0], canSave = p.gtin_check_ok && p.lot && p.expiry;
        api("/dispenses?ndc=" + encodeURIComponent(m.ndc11)).then(function (j) {
          document.getElementById("fills").innerHTML = '<p class="muted small">' + esc(m.drug) + " · NDC " + esc(ndc(m.ndc11)) + " · " + plural(j.dispenses.length, "fill") + " on record</p>" +
            '<p class="muted small">MIMIC moves every patient\'s dates far into the future (for example 2148) to protect privacy. Each patient\'s real dates are only known within a 3-year range that starts in 2011 or 2014.</p>' +
            '<div class="tablewrap"><table class="scan"><tr><th>Patient</th><th>Fill date (MIMIC, shifted)</th><th>Drug</th><th>Lot on record</th><th></th></tr>' +
            j.dispenses.map(function (d) {
              return "<tr><td>Patient " + esc(d.subject_id) + '</td><td class="mono">' + esc(d.starttime) + "</td><td>" + esc(d.drug) + " " + esc(d.strength) + "</td><td>" + (d.lot ? '<span class="pill ok">' + esc(d.lot) + "</span>" : '<span class="muted">none</span>') +
                "</td><td>" + (d.lot ? '<span class="pill ok">Recorded</span>' : '<button class="btn ghost rec" data-id="' + d.dispense_id + '"' + (canSave ? "" : " disabled") + ">Record lot here</button>") + "</td></tr>";
            }).join("") + "</table></div><div id=\"recres\"></div>";
          document.querySelectorAll(".rec").forEach(function (b) {
            b.onclick = function () {
              api("/barcode/record", { method: "POST", body: { raw: raw, dispense_id: +b.dataset.id } }).then(function (r) {
                document.getElementById("recres").innerHTML = '<div class="result ok">Lot ' + esc(r.lot) + " (exp " + esc(r.expiry) + ") recorded for patient " + esc(r.subject_id) + ". Recalls that name this lot now show this patient as exact.</div>";
                b.outerHTML = '<span class="pill ok">Recorded</span>';
              }).catch(function (e) { document.getElementById("recres").innerHTML = '<div class="result bad">' + esc(e.message) + "</div>"; });
            };
          });
        });
      }).catch(function (e) { document.getElementById("parsed").innerHTML = '<div class="result bad">' + esc(e.message) + "</div>"; });
    };
  }

  // ------------------------------------------------------------ accuracy
  function viewAccuracy() {
    setTab("accuracy");
    app.innerHTML = '<div class="empty">Loading results for 300 recalls...</div>';
    Promise.all([api("/accuracy"), api("/llmcalls")]).then(function (res) {
      var a = res[0], calls = res[1];
      function block(s, title) {
        if (!s) return "";
        return '<div class="card" style="margin-top:16px"><h2>' + esc(title) + '</h2><p class="muted small" style="margin-top:-6px">' + esc(s.extractor) + " · " + s.n + " recalls</p>" +
          '<div class="big3"><div><div class="n">' + s.ndc_product_hit_pct + '%</div><div>found an FDA product code (NDC)</div></div>' +
          '<div><div class="n">' + s.ndc_package_hit_pct + '%</div><div>found an exact FDA package NDC</div></div>' +
          '<div><div class="n">' + s.ingredient_hit_pct + '%</div><div>ingredient matches FDA generic name</div></div></div>' +
          '<p class="small">Extracted an NDC that FDA does not list: <b>' + s.with_wrong_ndc + "</b> recalls.</p>" +
          "<h2 style=\"margin-top:18px\">Where it missed (NDC or ingredient), " + s.wrong_examples.length + " shown</h2><div class=\"tablewrap\"><table class=\"acc\"><tr><th>Recall</th><th>FDA NDCs (hidden from the extractor)</th><th>Extracted</th><th>Ingredient read</th><th>FDA generic name</th></tr>" +
          s.wrong_examples.map(function (w) {
            return '<tr><td class="mono">' + esc(w.recall_number) + '</td><td class="mono small">' + esc(w.fda_ndcs.slice(0, 3).join(" ")) + (w.fda_ndcs.length > 3 ? " +" + (w.fda_ndcs.length - 3) : "") +
              '</td><td class="mono small">' + esc((w.extracted || []).slice(0, 3).join(" ") || "none") + "</td><td>" + esc(w.ingredient || "none") + '</td><td class="small">' + esc(w.fda_generic) + "</td></tr>";
          }).join("") + "</table></div>" +
          (s.extractor.indexOf("rule-based") >= 0 ? "" : '<p class="muted small">Some "misses" are FDA\'s own field, not the extractor: for D-0616-2021 Claude read "Insulin aspart", while FDA\'s generic name field says "WATER INJECTION". They are still counted as misses.</p>') + "</div>";
      }
      app.innerHTML = "<h1>How accurate is the reading?</h1>" +
        '<p class="sub">' + a.benchmark_size + " real FDA recalls. FDA's own NDC list is hidden from the extractor, which reads only the notice text. We compare its answers with FDA's list. Misses are listed below.</p>" +
        (a.llm ? block(a.llm, "AI Hub agent: Claude (recorded live replies)") :
          '<div class="card"><b>Live LLM accuracy: not measured in this build.</b><div class="muted small">No model was called when this image was built. Put a key in <span class="mono">.env</span> and run <span class="mono">tools/run_benchmark.sh</span>: every reply is recorded, then shown here and replayed without a key.</div></div>') +
        (a.tool_changed && a.tool_changed.consumer ? '<div class="card" style="margin-top:16px"><h2>The tool result changes the decision</h2>' +
          '<p>In <b>' + a.tool_changed.consumer + "</b> of the " + a.tool_changed.recordings + " recorded Claude runs the agent judged the recall consumer-level. In <b>" + a.tool_changed.contact +
          "</b> the LookupDispensed tool reported fills of the recalled NDCs and the agent chose patient contact. In the other <b>" + (a.tool_changed.shelf + a.tool_changed.none) +
          "</b> the tool reported 0 fills of the recalled NDCs here, so nobody is called: " + a.tool_changed.shelf + " shelf checks, " + a.tool_changed.none + " no action (never dispensed). Example: " + esc(a.tool_changed.example || "") + ".</p></div>" : "") +
        block(a.reference, "Rule-based reference extractor (baseline; replay uses it only for a recall with no recording)") +
        '<div class="card" style="margin-top:16px"><h2>Agent calls (traced as Interoperability messages)</h2><p class="muted small">Spent $' + (+calls.spent_usd).toFixed(2) + ". Each row is also an AgentRequest/AgentResponse pair in Visual Trace. In replay mode the agent runs for real but the reply comes from the local endpoint (a recorded Claude output, or a rule-based reply), so no model is called and no tokens are spent.</p>" +
        '<div class="tablewrap"><table><tr><th>Time (UTC)</th><th>Recall</th><th>Mode</th><th>Model</th><th>Tokens in/out</th><th>Cost</th><th>Latency</th><th>Trace</th></tr>' +
        calls.calls.slice(0, 20).map(function (c) {
          var live = c.mode === "live";
          return '<tr><td class="mono small">' + esc(c.ts) + '</td><td class="mono">' + esc(c.recall_number) + "</td><td>" + (live ? "live" : "replay") + "</td><td>" + (live ? esc(c.model) : '<span class="muted">none called</span>') + "</td><td>" + (live ? c.input_tokens + " / " + c.output_tokens : '<span class="muted">-</span>') +
            "</td><td>$" + (+c.cost_usd || 0).toFixed(2) + "</td><td>" + c.latency_ms + " ms</td><td>" + traceLink(c.session_id, "#" + c.session_id) + "</td></tr>";
        }).join("") + "</table></div></div>";
    }).catch(function (e) { app.innerHTML = '<div class="card empty">' + esc(e.message) + "</div>"; });
  }

  // ------------------------------------------------------------ audit
  var EVT = {
    "recall.arrived": "Recall arrived", "agent.tool_call": "Agent called a tool", "agent.decided": "Agent decided", "agent.refused": "Agent stopped",
    "agent.invalid_reply": "Agent reply rejected", "agent.tool_denied": "Tool call refused", "patients.ranked": "Patients ranked", "shelf.task": "Shelf check created",
    "shelf.done": "Shelf check done", "approval.requested": "Approval requested", "approval.approved": "Approved", "approval.rejected": "Rejected",
    "approval.expired": "Approval expired", "approval.cancelled": "Approval cancelled", "actions.executed": "Actions done", "action.refused": "Action refused",
    "lot.captured": "Lot recorded", "killswitch.on": "Kill switch on", "killswitch.off": "Kill switch off", "demo.reset": "Demo reset",
    "recall.error": "Error", "recall.stopped": "Stopped",
  };
  function viewAudit() {
    setTab("audit");
    api("/audit").then(function (j) {
      app.innerHTML = '<div class="row wrap"><div><h1>Audit trail</h1><p class="sub">Every agent step and every human decision, newest first. Rows from an Interoperability session link to IRIS Visual Trace (portal login needed).</p></div><span class="spacer"></span>' +
        '<button class="btn ghost" id="reset">Reset demo</button></div>' +
        '<div class="card"><div class="timeline">' + j.events.map(function (e) {
          var text = e.summary || e.detail || "";
          return '<div class="evt"><div class="mono small muted">' + esc(e.ts) + ' UTC</div><div><div class="e">' + esc(EVT[e.event] || e.event) + '</div><div class="muted small">' + esc(e.actor) + "</div></div>" +
            "<div>" + (e.recall_number ? '<a class="mono small" href="#/recall/' + encodeURIComponent(e.recall_number) + '">' + esc(e.recall_number) + "</a> " : "") + esc(text) +
            (e.detail && e.summary ? '<details><summary>details</summary><pre>' + esc(e.detail) + "</pre></details>" : "") + "</div>" +
            "<div class=\"small\">" + traceLink(e.session_id, "Visual Trace") + "</div></div>";
        }).join("") + "</div></div>";
      document.getElementById("reset").onclick = function () {
        if (!window.confirm("Reset the demo? Recorded lots, approvals and calls will be cleared.")) return;
        api("/demo/reset", { method: "POST" }).then(function () { toast("Demo reset"); state.seen = {}; location.hash = "#/"; });
      };
    });
  }

  // ------------------------------------------------------------ router
  function route() {
    stopPoll();
    var h = location.hash.replace(/^#/, "") || "/";
    var q = h.split("?"), p = q[0].split("/").filter(Boolean), spin = /spin=1/.test(q[1] || "");
    if (!p.length) return viewInbox();
    if (p[0] === "recall" && p[2] === "patients") return viewPatients(decodeURIComponent(p[1]), spin);
    if (p[0] === "recall") return viewRecall(decodeURIComponent(p[1]));
    if (p[0] === "approve") return viewApproval(p[1]);
    if (p[0] === "scan") return viewScan();
    if (p[0] === "accuracy") return viewAccuracy();
    if (p[0] === "audit") return viewAudit();
    viewInbox();
  }
  window.addEventListener("hashchange", route);
  refreshStatus().then(route);
  setInterval(refreshStatus, 5000);
})();
