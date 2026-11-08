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
    var t = document.createElement("div"); t.className = "toast"; t.textContent = msg;
    document.body.appendChild(t); setTimeout(function () { t.remove(); }, 2200);
  }
  function pct(p) {
    if (p == null) return "-";
    if (p >= 0.995) return "100%";
    if (p > 0 && p < 0.01) return "<1%";
    return Math.round(p * 100) + "%";
  }
  function clsPill(c) {
    var k = c === "Class I" ? "c1" : c === "Class II" ? "c2" : "c3";
    return '<span class="pill ' + k + '">' + esc(c || "Unclassified") + "</span>";
  }
  var STATUS = {
    "new": ["Just arrived", "blue"], reading: ["AI agent reading", "blue"], ready: ["Ready for pharmacist", "warn"],
    awaiting_approval: ["Waiting for approval", "warn"], approved: ["Done: approved", "ok"], rejected: ["Rejected", "bad"],
    expired: ["Approval expired", "bad"], no_patients: ["No patients", ""], stopped: ["Stopped", "bad"], error: ["Error", "bad"],
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
  function sourceLabel(src) {
    return src === "llm" ? "Live LLM reply" : src === "replay-recorded" ? "Recorded LLM reply (replay)" : "Rule-based reference reply (replay, no API key)";
  }
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
      else { m.className = "mode"; m.textContent = "Replay mode · no API key"; }
      m.title = s.mode === "live" ? "Anthropic via IRIS AI Hub. Spent $" + (+s.spent_usd).toFixed(4) + " of $" + s.spend_cap_usd :
        "IRIS AI Hub agent runs against the local replay endpoint (recorded or rule-based replies). Set ANTHROPIC_API_KEY for live mode.";
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
      '<div class="inbox-head"><div><h1>FDA recall inbox</h1><p class="sub" style="margin:0">Every new FDA drug recall is read by the IRIS AI Hub agent, then matched against your dispensing records.</p></div>' +
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
        var right = busy
          ? '<div class="count"><span class="reading">AI Hub agent is reading <span class="dots"><span></span><span></span><span></span></span></span></div>'
          : r.status === "error" || r.status === "stopped" ? '<div class="count"><div class="l">' + esc(r.error || r.status) + "</div></div>"
          : '<div class="count"><div class="n">' + (r.shown || 0) + '</div><div class="l">patient' + (r.shown === 1 ? "" : "s") + " likely affected</div>" +
            (r.hidden ? '<div class="h">' + r.hidden + " low-likelihood hidden</div>" : "") + "</div>";
        return '<a class="card rcard' + (fresh || (state.newest === r.recall_number && busy) ? " new" : "") + '" href="#/recall/' + encodeURIComponent(r.recall_number) + '">' +
          '<div><div class="meta">' + clsPill(r.classification) + statusPill(r.status) +
          '<span class="muted small">' + esc(r.recall_number) + " · " + esc(ago(r.arrived_at, j.now)) + "</span></div>" +
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
      var act = { hold_and_contact: "Hold next fills and contact patients", stock_check: "Pull shelf stock only", no_action: "No action needed" }[r.action] || "-";
      app.innerHTML =
        '<div class="crumbs"><a href="#/">Recalls</a> / ' + esc(rn) + "</div>" +
        '<div class="row" style="margin-bottom:6px">' + clsPill(r.classification) + statusPill(r.status) + '<span class="muted small">FDA report ' + esc(fdaDate(r.report_date)) + " · initiated " + esc(fdaDate(r.initiation_date)) + "</span></div>" +
        "<h1>" + esc(shortName(r.product)) + "</h1>" +
        '<p class="sub">' + esc(r.reason) + "</p>" +
        '<div class="grid2">' +
        '<div class="card"><div class="row"><h2 style="margin:0">FDA notice</h2><span class="spacer"></span><a class="small" target="_blank" rel="noopener" href="' + esc(r.fda.url) + '">Source on openFDA</a></div>' +
        '<p class="muted small" style="margin:4px 0 14px">The agent reads only this text. FDA\'s own NDC list is hidden from it (used on the Accuracy page).</p>' +
        '<div class="notice" id="notice">' + highlight(r.notice || "", fields) + "</div></div>" +
        '<div><div class="card"><div class="row"><h2 style="margin:0">What the agent read</h2><span class="spacer"></span>' +
        (ex.low_confidence ? '<span class="pill warn">' + ex.low_confidence + " need a human look</span>" : '<span class="pill ok">All fields have evidence</span>') + "</div>" +
        '<p class="muted small" style="margin:4px 0 14px">Click a field to see its evidence in the notice. Yellow = low confidence.</p>' +
        (busy ? '<div class="reading">AI Hub agent is reading <span class="dots"><span></span><span></span><span></span></span></div>' :
          '<div class="fields" id="fields">' + fields.map(function (f, i) {
            var v = f.value || "(not stated)";
            if (f.key === "lot" && f.expiry) v += " · exp " + f.expiry;
            return '<div class="field' + (f.confidence === "low" ? " low" : "") + '" data-f="' + i + '"><div class="k">' + esc(f.label) + '</div><div class="v">' + esc(v) + "</div>" +
              '<span class="pill ' + (f.confidence === "low" ? "warn" : "ok") + '">' + esc(f.confidence) + "</span>" +
              (f.note ? '<div class="note">' + esc(f.note) + "</div>" : "") + "</div>";
          }).join("") + "</div>") +
        '<div class="decision"><div class="muted small">Agent decision</div><div class="a">' + esc(act) + "</div><div>" + esc(r.rationale || "") + "</div>" +
        '<div class="muted small" style="margin-top:8px">' + esc(sourceLabel(r.source)) + " · model " + esc(r.model || "-") + " · " + traceLink(r.session_id, "Open in Visual Trace") + "</div></div>" +
        "</div>" +
        '<div class="cta">' + (r.status === "no_patients" ? '<span class="muted">No dispensed product matches this recall.</span>' :
          '<button class="btn big" id="find"' + (busy ? " disabled" : "") + ">Find patients</button>") +
        '<span class="muted small">' + (r.shown != null ? "" : "") + "</span></div></div></div>";
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
      if (busy) { stopPoll(); state.poll = setTimeout(function () { viewRecall(rn); }, 1500); }
    }).catch(function (e) { app.innerHTML = '<div class="card empty">' + esc(e.message) + "</div>"; });
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
    var badges = (row.badges || []).map(function (b) {
      var k = b === "Lot confirmed" ? "ok" : b === "Lot cleared" ? "" : b === "NDC match" ? "blue" : "warn";
      return '<span class="pill ' + k + '">' + esc(b) + "</span>";
    }).join("");
    if (row.on_hold) badges += '<span class="pill ok">Next fill on hold</span>';
    if (row.on_contact_list) badges += '<span class="pill ok">On call list</span>';
    var html = '<div class="prow' + (opts.top ? " top" : "") + '" data-sid="' + esc(row.subject_id) + '">' +
      '<div class="rank">' + (i + 1) + "</div>" +
      '<div><div class="who">Patient ' + esc(row.subject_id) + '</div><div class="muted small">' + esc(row.sex === "F" ? "Female" : row.sex === "M" ? "Male" : "") + (row.age ? ", " + esc(row.age) : "") + "</div>" +
      (badges ? '<div class="badges">' + badges + "</div>" : "") + "</div>" +
      '<div class="drug"><div>' + esc(row.drug) + " " + esc(row.strength || "") + '</div><div class="muted small mono">NDC ' + esc(row.ndc_pretty || "none on record") + "</div></div>" +
      '<div class="when small">' + esc(row.fills) + " fill" + (row.fills === 1 ? "" : "s") + '<div class="muted">' + esc(windowText(row)) + "</div></div>" +
      '<div class="p">' + (row.exact ? (row.p >= 1 ? "100%" : "0%") : pct(row.p)) + "<small>" + (row.exact ? "exact (barcode lot)" : "estimate") + "</small></div>";
    if (!opts.reel) {
      html += '<div class="acts"><label><input type="checkbox" class="h" ' + (opts.checked ? "checked" : "") + "> Hold next fill</label>" +
        '<label><input type="checkbox" class="c" ' + (opts.checked ? "checked" : "") + "> Call patient</label>" +
        '<button class="exp">Why ' + (row.exact ? "exact" : pct(row.p)) + "?</button></div>";
      html += '<div class="detail">' + factorHtml(row) + "</div>";
    }
    return html + "</div>";
  }
  function factorHtml(row) {
    var f = (row.best && row.best.factors) || [];
    var formula = row.exact ? "Barcode lot on the dispensing record = exact answer"
      : "P(fill) = " + f.map(function (x) { return x.name.toLowerCase(); }).join(" x ") +
        "<br>P(fill) = " + f.map(function (x) { return (+x.value).toFixed(3); }).join(" x ") + " = " + (+(row.best.p || 0)).toFixed(3) +
        (row.fills > 1 ? "<br>P(patient) = 1 - product(1 - P(fill)) over " + row.fills + " fills = " + (+row.p).toFixed(3) : "");
    return '<div class="formula">' + formula + "</div>" + f.map(function (x) {
      return '<div class="factor"><div><b>' + esc(x.name) + '</b><div class="src">' + esc(x.source) + '</div></div><div class="fv">' + (+x.value).toFixed(3) + "</div><div>" + esc(x.why) +
        (x.caveat ? '<div class="src">' + esc(x.caveat) + "</div>" : "") + "</div></div>";
    }).join("") + '<p class="muted small" style="margin:8px 0 0">Estimate, not a diagnosis. Scan the lot barcode at dispensing to make this exact.</p>';
  }
  function viewPatients(rn, spin) {
    setTab("inbox");
    app.innerHTML = '<div class="empty">Loading...</div>';
    Promise.all([api("/recalls/" + encodeURIComponent(rn)), api("/recalls/" + encodeURIComponent(rn) + "/patients")]).then(function (res) {
      var r = res[0], d = res[1];
      var shown = d.shown || [], hidden = d.hidden || [];
      var locked = ["awaiting_approval", "approved"].indexOf(r.status) >= 0;
      app.innerHTML =
        '<div class="crumbs"><a href="#/">Recalls</a> / <a href="#/recall/' + encodeURIComponent(rn) + '">' + esc(rn) + "</a> / patients</div>" +
        '<div class="row">' + clsPill(r.classification) + statusPill(r.status) + "</div>" +
        "<h1>Who got " + esc(shortName(r.product)) + "?</h1>" +
        '<p class="sub">One list, highest estimated chance first. Below ' + pct(d.threshold) + " is folded away.</p>" +
        '<div class="stats">' +
        '<div class="card stat"><div class="n">' + shown.length + '</div><div class="l">likely affected (shown)</div></div>' +
        '<div class="card stat"><div class="n">' + hidden.length + '</div><div class="l">low-likelihood (hidden)</div></div>' +
        '<div class="card stat"><div class="n">' + (d.total || 0) + '</div><div class="l">patients with a matching fill</div></div>' +
        '<div class="card stat"><div class="n">' + (d.candidates || 0) + '</div><div class="l">fills checked (NDC + vector search)</div></div></div>' +
        '<div id="plist"></div>' +
        (hidden.length ? '<div class="hiddenbar" id="hb" style="margin-top:8px">' + hidden.length + " low-likelihood hidden · show</div>" : "") +
        '<div id="hlist" class="plist" style="margin-top:8px"></div>' +
        (r.approval && r.approval.status === "pending" ? '<div class="sticky"><div><b>Approval pending</b> <span class="muted">' + r.approval.seconds_left + " s left</span></div><span class=\"spacer\"></span>" +
          '<span class="muted small">The approval link was shown once to the pharmacist who asked for it.</span></div>' :
          (shown.length && !locked ? '<div class="sticky"><div><b id="sumtxt"></b><div class="muted small">A pharmacist must approve. The link expires in 10 minutes and works once.</div></div><span class="spacer"></span>' +
            '<button class="btn big" id="ask">Ask pharmacist approval</button></div>' : ""));
      var pl = document.getElementById("plist");
      function render() {
        pl.className = "plist";
        pl.innerHTML = shown.map(function (row, i) { return prow(row, i, { top: i === 0, checked: true }); }).join("") ||
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
        var t = document.getElementById("sumtxt"); if (t) t.textContent = "Hold next fill: " + h + " · Call: " + c;
      }
      var hb = document.getElementById("hb");
      if (hb) hb.onclick = function () {
        var hl = document.getElementById("hlist");
        if (hl.innerHTML) { hl.innerHTML = ""; hb.textContent = hidden.length + " low-likelihood hidden · show"; return; }
        hl.innerHTML = hidden.map(function (row, i) { return prow(row, shown.length + i, { checked: false }); }).join("");
        wire(hl); hb.textContent = "Hide " + hidden.length + " low-likelihood";
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
  // the "da-da-da ... ding" moment
  function spinReel(pl, shown, hidden, done) {
    var pool = shown.concat(hidden);
    var rows = [];
    var loops = Math.max(3, Math.ceil(36 / pool.length));
    for (var k = 0; k < loops; k++) { pool.slice().sort(function () { return Math.random() - 0.5; }).forEach(function (x) { rows.push(x); }); }
    rows.push(shown[0]);
    rows.push(shown[1] || pool[0]); rows.push(shown[2] || pool[0]); rows.push(pool[0]);
    pl.className = "";
    pl.innerHTML = '<div class="reelwrap"><div class="reel" id="reel">' + rows.map(function (r, i) { return prow(r, i, { reel: true }); }).join("") + '</div><div class="scanline"></div></div>';
    var reel = document.getElementById("reel");
    var items = reel.children, target = rows.length - 4;
    var wrapH = 520, rowH = items[0].getBoundingClientRect().height + 8;
    var dist = target * rowH - (wrapH / 2 - rowH / 2) + 8;
    var dur = 2200, t0 = performance.now(), lastIdx = -1;
    function ease(t) { return 1 - Math.pow(1 - t, 4); }
    function frame(now) {
      var t = Math.min(1, (now - t0) / dur), y = dist * ease(t);
      reel.style.transform = "translateY(" + (-y) + "px)";
      var idx = Math.floor(y / rowH);
      if (idx !== lastIdx) { lastIdx = idx; beep(700 + (idx % 5) * 40, 0.025, 0.025, "square"); }
      if (t < 1) requestAnimationFrame(frame);
      else {
        ding();
        var top = items[target]; top.classList.add("top", "zoom");
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
        '<div class="muted small">IRIS Workflow task "RecallReach approval #' + esc(a.id) + '" (role Pharmacist) is waiting. ' + traceLink(a.session_id, "Open in Visual Trace") + "</div>" +
        '<div id="st" style="margin-top:8px">' + statusPill(a.status === "pending" ? "awaiting_approval" : a.status) + "</div></div></div>" +
        '<div class="plan"><div class="card"><div class="n">' + a.plan.hold.length + '</div><div>next fills put on hold</div></div>' +
        '<div class="card"><div class="n">' + a.plan.contact.length + '</div><div>patients to call</div></div></div>' +
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
      if (a.status !== "pending") { document.getElementById("left").textContent = a.status === "approved" ? "Used" : "Closed"; }
      if (a.status !== "pending") { clearInterval(timer); lock(); showResult(a); }
      function decide(kind) {
        var body = kind === "reject" ? { reason: document.getElementById("why").value } : {};
        api("/approvals/" + encodeURIComponent(token) + "/" + kind, { method: "POST", body: body }).then(function () {
          clearInterval(timer); lock();
          document.getElementById("left").textContent = kind === "approve" ? "Used" : "Closed";
          setTimeout(function () { api("/approvals/" + encodeURIComponent(token)).then(showResult); }, 1200);
        }).catch(function (e) { document.getElementById("res").innerHTML = '<div class="result bad">' + esc(e.message) + "</div>"; });
      }
      document.getElementById("ok").onclick = function () { decide("approve"); };
      document.getElementById("no").onclick = function () { decide("reject"); };
      function showResult(x) {
        var st = document.getElementById("st"); if (st) st.innerHTML = statusPill(x.status === "pending" ? "awaiting_approval" : x.status);
        var res = document.getElementById("res"); if (!res) return;
        if (x.status === "approved") {
          res.innerHTML = '<div class="result ok"><b>Approved and done.</b> ' + (x.holds || 0) + " next fills on hold · " + (x.contacts || 0) + ' patients on the call list.<br><span class="small">Pressing Approve again on this link is refused: it is single use.</span></div>' +
            '<div class="row" style="margin-top:14px"><a class="btn ghost" href="#/recall/' + encodeURIComponent(rn) + '/patients">See the patient list</a><a class="btn ghost" href="#/audit">Audit trail</a></div>';
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
      "<h1>Scan the box at dispensing</h1><p class=\"sub\">The 2D GS1 DataMatrix on a US drug package carries the product code (GTIN/NDC), lot, expiry and serial. Record it once, and any future recall that names that lot is an exact match: no estimate needed.</p>" +
      '<div class="card"><div class="row"><h2 style="margin:0">1. Scan or paste the barcode</h2><span class="spacer"></span>' +
      '<button class="btn ghost" id="cam" hidden>Use camera</button><button class="btn ghost" id="sample">Use a sample barcode</button></div>' +
      '<p class="muted small">Scanners type the barcode like a keyboard. Both "(01)...(17)...(10)...(21)..." and raw strings with the group separator work.</p>' +
      '<textarea class="scanbox" id="raw" placeholder="(01)00368084060018(17)150930(10)131928(21)..."></textarea>' +
      '<video id="vid" playsinline muted style="display:none;width:100%;max-width:420px;border-radius:12px;margin-top:10px"></video>' +
      '<div class="row" style="margin-top:10px"><button class="btn" id="parse">Read barcode</button></div><div id="parsed"></div></div>' +
      '<div class="card" style="margin-top:16px" id="step2" hidden><h2>2. Which fill is this box for?</h2><div id="fills"></div></div>';
    document.getElementById("sample").onclick = function () {
      api("/barcode/sample").then(function (s) { document.getElementById("raw").value = s.raw; toast("Sample: recalled lot " + s.lot + " of NDC " + s.ndc11); });
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
        var cell = function (k, v) { return '<div class="card"><div class="k">' + k + '</div><div class="v">' + esc(v || "-") + "</div></div>"; };
        document.getElementById("parsed").innerHTML = '<div class="parsed">' + cell("GTIN (01)", p.gtin + (p.gtin_check_ok ? " ✓" : " (check digit wrong)")) +
          cell("NDC (10-digit)", p.ndc10) + cell("Lot (10)", p.lot) + cell("Expiry (17)", p.expiry) + cell("Serial (21)", p.serial) + "</div>";
        var s2 = document.getElementById("step2"); s2.hidden = false;
        if (!p.matches.length) { document.getElementById("fills").innerHTML = '<p class="muted">No dispensing record has this NDC.</p>'; return; }
        var m = p.matches[0];
        api("/dispenses?ndc=" + encodeURIComponent(m.ndc11)).then(function (j) {
          document.getElementById("fills").innerHTML = '<p class="muted small">' + esc(m.drug) + " · NDC " + esc(m.ndc11) + " · " + j.dispenses.length + ' fills on record</p><table><tr><th>Patient</th><th>Fill (MIMIC shifted date)</th><th>Drug</th><th>Lot on record</th><th></th></tr>' +
            j.dispenses.map(function (d) {
              return "<tr><td>Patient " + esc(d.subject_id) + '</td><td class="mono">' + esc(d.starttime) + "</td><td>" + esc(d.drug) + " " + esc(d.strength) + "</td><td>" + (d.lot ? '<span class="pill ok">' + esc(d.lot) + "</span>" : '<span class="muted">none</span>') +
                '</td><td><button class="btn ghost rec" data-id="' + d.dispense_id + '">Record lot here</button></td></tr>';
            }).join("") + "</table>";
          document.querySelectorAll(".rec").forEach(function (b) {
            b.onclick = function () {
              api("/barcode/record", { method: "POST", body: { raw: raw, dispense_id: +b.dataset.id } }).then(function (r) {
                toast("Lot " + r.lot + " recorded for patient " + r.subject_id);
                b.outerHTML = '<span class="pill ok">Recorded</span>';
              }).catch(function (e) { toast(e.message); });
            };
          });
        });
      }).catch(function (e) { document.getElementById("parsed").innerHTML = '<div class="result bad">' + esc(e.message) + "</div>"; });
    };
  }

  // ------------------------------------------------------------ accuracy
  function viewAccuracy() {
    setTab("accuracy");
    app.innerHTML = '<div class="empty">Measuring on 300 real recalls...</div>';
    Promise.all([api("/accuracy"), api("/llmcalls")]).then(function (res) {
      var a = res[0], calls = res[1];
      function block(s, title) {
        if (!s) return "";
        return '<div class="card" style="margin-top:16px"><h2>' + esc(title) + '</h2><p class="muted small" style="margin-top:-6px">' + esc(s.extractor) + " · " + s.n + " recalls</p>" +
          '<div class="big3"><div><div class="n">' + s.ndc_product_hit_pct + '%</div><div>found an FDA product code (NDC)</div></div>' +
          '<div><div class="n">' + s.ndc_package_hit_pct + '%</div><div>found an exact FDA package NDC</div></div>' +
          '<div><div class="n">' + s.ingredient_hit_pct + '%</div><div>ingredient matches FDA generic name</div></div></div>' +
          '<p class="small">Extracted an NDC that FDA does not list: <b>' + s.with_wrong_ndc + "</b> recalls.</p>" +
          "<h2 style=\"margin-top:18px\">Where it was wrong (" + s.wrong_examples.length + " shown)</h2><table><tr><th>Recall</th><th>FDA NDCs (hidden from the extractor)</th><th>Extracted</th><th>Ingredient read</th><th>FDA generic name</th></tr>" +
          s.wrong_examples.map(function (w) {
            return '<tr><td class="mono">' + esc(w.recall_number) + '</td><td class="mono small">' + esc(w.fda_ndcs.slice(0, 3).join(" ")) + (w.fda_ndcs.length > 3 ? " +" + (w.fda_ndcs.length - 3) : "") +
              '</td><td class="mono small">' + esc((w.extracted || []).slice(0, 3).join(" ") || "none") + "</td><td>" + esc(w.ingredient) + '</td><td class="small">' + esc(w.fda_generic) + "</td></tr>";
          }).join("") + "</table></div>";
      }
      app.innerHTML = "<h1>How accurate is the reading?</h1>" +
        '<p class="sub">We take ' + a.benchmark_size + " real FDA recalls that carry FDA's own harmonized NDC list, hide that list, let the extractor read only the free text, and compare. Wrong cases are listed, not hidden.</p>" +
        (a.llm ? block(a.llm, "AI Hub agent (recorded live replies)") :
          '<div class="card"><b>Live LLM accuracy: not measured in this build.</b><div class="muted small">No API key was available when this image was built. Set ANTHROPIC_API_KEY and run <span class="mono">tools/run_benchmark.sh</span>: every reply is recorded, then shown here and replayed without a key.</div></div>') +
        block(a.reference, "Rule-based reference extractor (used in replay mode)") +
        '<div class="card" style="margin-top:16px"><h2>LLM calls (traced as Interoperability messages)</h2><p class="muted small">Spent $' + (+calls.spent_usd).toFixed(4) + '. Each row is also an AgentRequest/AgentResponse pair in Visual Trace.</p>' +
        "<table><tr><th>Time (UTC)</th><th>Recall</th><th>Mode</th><th>Model</th><th>Tokens in/out</th><th>Cost</th><th>Latency</th><th>Trace</th></tr>" +
        calls.calls.slice(0, 20).map(function (c) {
          return '<tr><td class="mono small">' + esc(c.ts) + '</td><td class="mono">' + esc(c.recall_number) + "</td><td>" + esc(c.mode) + "</td><td>" + esc(c.model) + "</td><td>" + c.input_tokens + " / " + c.output_tokens +
            "</td><td>$" + (+c.cost_usd || 0).toFixed(5) + "</td><td>" + c.latency_ms + " ms</td><td>" + traceLink(c.session_id, "#" + c.session_id) + "</td></tr>";
        }).join("") + "</table></div>";
    }).catch(function (e) { app.innerHTML = '<div class="card empty">' + esc(e.message) + "</div>"; });
  }

  // ------------------------------------------------------------ audit
  function viewAudit() {
    setTab("audit");
    api("/audit").then(function (j) {
      app.innerHTML = '<div class="row"><div><h1>Audit trail</h1><p class="sub">Everything the agent decided and every human decision, newest first. Each session links to IRIS Visual Trace.</p></div><span class="spacer"></span>' +
        '<button class="btn ghost" id="reset">Reset demo</button></div>' +
        '<div class="card"><div class="timeline">' + j.events.map(function (e) {
          return '<div class="evt"><div class="mono small muted">' + esc(e.ts) + ' UTC</div><div><div class="e">' + esc(e.event) + '</div><div class="muted small">' + esc(e.actor) + "</div></div>" +
            "<div>" + (e.recall_number ? '<a class="mono small" href="#/recall/' + encodeURIComponent(e.recall_number) + '">' + esc(e.recall_number) + "</a> " : "") + esc(e.detail) + "</div>" +
            "<div class=\"small\">" + traceLink(e.session_id, "trace") + "</div></div>";
        }).join("") + "</div></div>";
      document.getElementById("reset").onclick = function () {
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
