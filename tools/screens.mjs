// Headless walk-through of the demo + screenshots (no window is opened).
//   BASE=http://localhost:52795 OUT=_screens node tools/screens.mjs
// Also: SPINCHECK=dir  -> spins the reel 10 times at 1440 and 390 px and checks it stops on the #1 patient
//       GIFDIR=dir     -> records the "recall arrives -> agent reads -> Find patients -> ding" video for the README GIF
import { chromium } from "playwright";
import fs from "fs";
const BASE = process.env.BASE || "http://localhost:52795";
const OUT = process.env.OUT || "_screens";
const SPIN = process.env.SPINCHECK || "";
const GIFDIR = process.env.GIFDIR || "";
const UI = BASE + "/recallreach/index.html";
const api = (p, m = "GET", b) => fetch(BASE + "/recallreach/api" + p, { method: m, headers: { "Content-Type": "application/json" }, body: b ? JSON.stringify(b) : undefined }).then(r => r.json().then(j => ({ s: r.status, j })));
const sleep = ms => new Promise(r => setTimeout(r, ms));
const log = (...a) => console.log(...a);
fs.mkdirSync(OUT, { recursive: true });

const b = await chromium.launch({ headless: true, executablePath: process.env.CHROME || undefined });
const ctx = await b.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 });
const page = await ctx.newPage();
page.on("pageerror", e => log("PAGE ERROR", e.message));
page.on("dialog", d => d.accept());
const shot = async (n, full = false) => { await page.screenshot({ path: `${OUT}/${n}.png`, fullPage: full }); log("shot", n); };

const meta = (await api("/barcode/sample")).j;           // demo recall + the box the pharmacist scanned
const RN = process.env.RN || meta.recall_number;
const FILL = meta.dispense_id;
const SHELF_RN = process.env.SHELF_RN || "D-1226-2015";  // a retail-level recall (shelf-check branch)

await api("/demo/reset", "POST");
// the pharmacist scanned the box when filling this patient's prescription
await page.goto(UI + "#/scan");
await page.click("#sample"); await sleep(500); await page.click("#parse");
await page.waitForSelector(`.rec[data-id="${FILL}"]`, { timeout: 15000 });
await page.click(`.rec[data-id="${FILL}"]`); await sleep(700);
await page.locator(`#recres`).scrollIntoViewIfNeeded();
await shot("00_scan_lot_at_dispensing");

async function waitRead(p, rn) {
  await p.waitForFunction(rn => [...document.querySelectorAll(".rcard")].some(c => c.href.includes(rn) && c.querySelector(".count .n")), rn, { timeout: 90000 });
}

if (GIFDIR) {
  // one continuous recording: inbox -> new recall arrives -> agent reads -> open -> Find patients -> spin -> ding
  fs.mkdirSync(GIFDIR, { recursive: true });
  const vctx = await b.newContext({ viewport: { width: 1280, height: 760 }, recordVideo: { dir: GIFDIR, size: { width: 1280, height: 760 } } });
  const vp = await vctx.newPage();
  await vp.goto(UI + "#/"); await vp.waitForSelector(".rcard"); await sleep(900);
  await vp.click("#sim");
  await waitRead(vp, RN); await sleep(1300);
  await vp.goto(UI + "#/recall/" + RN); await vp.waitForSelector("#find"); await sleep(1600);
  await vp.click("#find");
  await vp.waitForFunction(() => document.getElementById("reelwrap") && document.getElementById("reelwrap").dataset.landed, null, { timeout: 15000 });
  await sleep(2600);
  const vpath = await vp.video().path();
  await vctx.close();
  fs.renameSync(vpath, GIFDIR + "/spin.webm");
  log("video", GIFDIR + "/spin.webm");
} else {
  await page.goto(UI + "#/");
  await page.waitForSelector(".rcard");
  await page.click("#sim");
  await waitRead(page, RN);
}

await page.goto(UI + "#/");
await page.waitForSelector(".rcard"); await sleep(400);
await shot("01_inbox");
await page.goto(UI + "#/recall/" + RN);
await page.waitForSelector(".field"); await sleep(300);
await shot("02_recall_detail_patient_contact");
await shot("02b_recall_detail_full", true);
await page.goto(UI + "#/recall/" + SHELF_RN);
await page.waitForSelector(".shelf"); await sleep(300);
await shot("03_recall_detail_shelf_check");
await page.goto(UI + "#/recall/" + RN);
await page.waitForSelector("#find");
await page.click("#find");
await sleep(1000); await shot("04_find_patients_spinning");
await page.waitForFunction(() => document.getElementById("reelwrap") && document.getElementById("reelwrap").dataset.landed, null, { timeout: 15000 });
await shot("05_spin_stops_on_top_patient");
await sleep(1800); await shot("06_patient_list_top");
await page.click("#plist .prow .exp"); await sleep(300);
await shot("07_why_this_estimate");
await page.click("#hb").catch(() => {}); await sleep(300);
await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight)); await sleep(300);
await shot("08_hidden_low_likelihood");
await page.click("#ask");
await page.waitForSelector("#ok"); await sleep(1200);
await shot("09_approval_10min_single_use");
await page.click("#ok"); await sleep(3500);
await page.click("#again").catch(() => {}); await sleep(800);
await page.evaluate(() => window.scrollTo(0, document.body.scrollHeight)); await sleep(200);
await shot("10_approved_and_reuse_refused");
await page.goto(UI + "#/recall/" + RN + "/patients");
await sleep(1500); await shot("11_after_approval");
await page.goto(UI + "#/accuracy");
await page.waitForSelector(".big3", { timeout: 60000 }); await sleep(300);
await shot("13_accuracy");
await page.goto(UI + "#/audit");
await page.waitForSelector(".evt"); await sleep(300);
await page.evaluate(() => { const d = document.querySelector(".evt details"); if (d) d.open = true; });
await shot("14_audit_trail");

// Visual Trace of the demo recall's triage session (Management Portal, demo login)
const rec = (await api("/recalls/" + RN)).j;
if (rec.session_id) {
  const vt = await ctx.newPage();
  await vt.goto(`${BASE}/csp/user/EnsPortal.VisualTrace.zen?SESSIONID=${rec.session_id}`);
  await sleep(1500);
  if (await vt.$('input[name="IRISUsername"]')) {        // demo portal login (_SYSTEM / SYS, see README)
    await vt.fill('input[name="IRISUsername"]', "_SYSTEM"); await vt.fill('input[name="IRISPassword"]', "SYS");
    await Promise.all([vt.waitForLoadState("load"), vt.click('input[type="submit"], #loginButton, button')]);
  }
  await sleep(5000);
  await vt.screenshot({ path: `${OUT}/16_visual_trace.png` }); log("shot 16_visual_trace");
  const shelfRec = (await api("/recalls/" + SHELF_RN)).j;
  await vt.goto(`${BASE}/csp/user/EnsPortal.VisualTrace.zen?SESSIONID=${shelfRec.session_id}`);
  await sleep(4000);
  await vt.screenshot({ path: `${OUT}/17_visual_trace_shelf_check.png` }); log("shot 17_visual_trace_shelf_check");
  await vt.close();
}

// phone width: every screen, and no sideways scrolling
await page.setViewportSize({ width: 390, height: 844 });
const phone = [["20_phone_inbox", "#/"], ["21_phone_recall", "#/recall/" + RN], ["22_phone_shelf_check", "#/recall/" + SHELF_RN],
  ["23_phone_patients", "#/recall/" + RN + "/patients"], ["24_phone_scan", "#/scan"], ["25_phone_accuracy", "#/accuracy"], ["26_phone_audit", "#/audit"]];
for (const [n, h] of phone) {
  await page.goto(UI + h); await sleep(1800);
  if (n === "24_phone_scan") { await page.click("#sample"); await sleep(400); await page.click("#parse"); await sleep(1200); }
  if (n === "23_phone_patients") { await page.click("#plist .prow .exp").catch(() => {}); await sleep(300); }
  const w = await page.evaluate(() => document.documentElement.scrollWidth);
  log(n, "scrollWidth", w, w <= 390 ? "ok" : "OVERFLOW");
  await shot(n, true);
}

if (SPIN) {
  fs.mkdirSync(SPIN, { recursive: true });
  // the demo recall was approved above; spin on another consumer-level recall that still has an open list
  const SRN = process.env.SPIN_RN || "D-0668-2016";
  const top = (await api(`/recalls/${SRN}/patients`)).j.shown[0].subject_id;
  let ok = 0, n = 0;
  for (const [w, h] of [[1440, 900], [390, 844]]) {
    await page.setViewportSize({ width: w, height: h });
    for (let i = 1; i <= 10; i++) {
      await page.goto(UI + "#/"); await sleep(200);
      await page.goto(UI + `#/recall/${SRN}/patients?spin=1`);
      await page.waitForFunction(() => document.getElementById("reelwrap") && document.getElementById("reelwrap").dataset.landed, null, { timeout: 15000 });
      const r = await page.evaluate(() => {
        const wrap = document.getElementById("reelwrap"), line = document.getElementById("scanline");
        const t = document.querySelector("#reel .prow.top");
        const a = t.getBoundingClientRect(), l = line.getBoundingClientRect(), wr = wrap.getBoundingClientRect();
        return { sid: t.dataset.sid, rank: t.querySelector(".rank").textContent, dy: Math.round((a.top + a.height / 2) - (l.top + l.height / 2)), inside: a.top >= wr.top && a.bottom <= wr.bottom };
      });
      const pass = r.sid === top && Math.abs(r.dy) <= 3 && r.inside;
      n++; if (pass) ok++;
      await page.screenshot({ path: `${SPIN}/spin_${w}_${String(i).padStart(2, "0")}.png` });
      log(`spin ${w}px #${i}: under the line = patient ${r.sid} (rank ${r.rank}), expected ${top}, offset ${r.dy}px -> ${pass ? "PASS" : "FAIL"}`);
    }
  }
  log(`SPIN RESULT ${ok}/${n}`);
}
await b.close();
