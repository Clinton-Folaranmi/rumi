// Rumi — the search panel's logic, shared by the app (⌘F) and the menu-bar panel.
// Empty: what you opened lately, then your biggest files. Typing: Rumi's map answers at once (folders and big files),
// Spotlight fills in every other file a moment later.
// The page supplies three things: findGo(item, mode) to act on a result, findClose(), and optionally findGone().
// Modes: "open" (↵) opens the thing itself, "finder" (⌘↵) shows where it is, "map" (⌥↵) shows it on Rumi's map.
const findMode = e => e.metaKey ? "finder" : e.altKey ? "map" : "open";
const F = { q: "", seq: 0, idx: [], spot: [], spotDone: false, items: [], sel: 0, moved: false, empty: null, t: 0 };
const ICON_SEARCH = `<svg class="i" viewBox="0 0 16 16"><circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5 14 14"/></svg>`;
const isFolder = k => k.type === "dir" && !k.pkg && !isApp(k);
const recent = {
  get() { try { return JSON.parse(localStorage.getItem("rumi-recent") || "[]"); } catch { return []; } },
  add(k) { try { const r = recent.get().filter(x => x.path !== k.path); r.unshift({ path: k.path, name: k.name, size: k.size, type: k.type, cat: k.cat, pkg: !!k.pkg });
    localStorage.setItem("rumi-recent", JSON.stringify(r.slice(0, 5))); } catch {} },
  drop(p) { try { localStorage.setItem("rumi-recent", JSON.stringify(recent.get().filter(x => x.path !== p))); } catch {} },
};
// what a row points at was moved or deleted since it was listed: the row says so, and Recent forgets it
function findMissing(k) {
  recent.drop(k.path);
  const s = $("f-list").querySelector(`.fr[data-i="${F.items.indexOf(k)}"] small`); if (s) s.textContent = "Not there any more";
}
// keep: the same search asked again (the map just came back), so the row you're on stays picked
async function findRun(keep) {
  const q = $("f-q").value.trim(), seq = ++F.seq; F.q = q; if (keep !== true) { F.sel = 0; F.moved = false; }
  if (!q) {
    F.idx = F.spot = []; F.empty = { recent: recent.get(), big: F.empty?.big || [] }; findDraw();
    const r = await api(`/api/search?q=`).catch(() => null); // (while the map is being read back the answer is empty: the list already shown stays until the real one arrives)
    if (seq === F.seq && r && (r.results.length || !F.empty.big.length)) { F.empty.big = r.results; findDraw(); }
    return;
  }
  F.empty = null; F.spotDone = !NATIVE;
  const get = src => api(`/api/search?src=${src}&q=${encodeURIComponent(q)}`).catch(() => null);
  get("index").then(r => { if (seq === F.seq && r && !r.stale) { F.idx = r.results; F.idxQ = q; findDraw(); } });
  if (NATIVE) get("spotlight").then(r => { if (seq === F.seq && r && !r.stale) { F.spot = r.results; F.spotQ = q; F.spotDone = true; findDraw(); } });
}
const fRow = (k, i, q) => {
  const name = label(k), m = q ? new RegExp(q.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "i").exec(name) : null;
  const hl = m ? esc(name.slice(0, m.index)) + "<mark>" + esc(m[0]) + "</mark>" + esc(name.slice(m.index + m[0].length)) : esc(name);
  // the full path shows when you point at the name itself; each row has its own Show in Finder button
  return `<div class="fr ${i === F.sel ? "sel" : ""}" data-i="${i}">${tile(k)}<div class="fm"><b data-tip="${esc(tilde(k.path))}">${hl}</b><small>${esc(whereOf(k.path))}</small></div><span class="num">${k.size ? fmt(k.size) : ""}</span><button class="ffind" data-tip="Show in Finder · ⌘↵" aria-label="Show in Finder">${ICON.finder}</button></div>`;
};
function findDraw() {
  // results that arrive later re-sort the list: the row you moved to stays the one that's picked
  const L = $("f-list"), keep = F.moved ? F.items[F.sel]?.path : null, sects = [];
  const sect = (title, list) => { if (list.length) sects.push([title, list]); };
  let none = "";
  F.drawnQ = F.empty ? "" : F.q;
  if (F.empty) {
    sect("Recent", F.empty.recent); sect("Biggest files", F.empty.big);
    $("f-n").textContent = "";
  } else {
    const seen = new Map();
    for (const k of [...(F.idxQ === F.q ? F.idx : []), ...(F.spotQ === F.q ? F.spot : [])]) if (!seen.has(k.path)) seen.set(k.path, k);
    const all = [...seen.values()].sort((a, b) => a.score - b.score || b.size - a.size);
    const dirs = all.filter(isFolder), files = all.filter(k => !isFolder(k));
    sect("Folders", dirs.slice(0, 4)); sect("Files", files.slice(0, 40));
    $("f-n").textContent = all.length ? `${all.length >= 200 ? "200+" : all.length} found` : F.spotDone ? "" : "…";
    if (!all.length && F.spotDone) none = `<div class="fnone">Nothing named “${esc(F.q)}”</div>`;
  }
  F.items = sects.flatMap(s => s[1]);
  F.sel = keep ? Math.max(0, F.items.findIndex(k => k.path === keep)) : 0;
  let i = 0;
  L.innerHTML = none || sects.map(([title, list]) => `<div class="fh">${title}</div>` + list.map(k => fRow(k, i++, F.q)).join("")).join("");
}
function findMove(d) {
  if (!F.items.length) return;
  F.moved = true;
  F.sel = (F.sel + d + F.items.length) % F.items.length;
  $("f-list").querySelectorAll(".fr").forEach(r => r.classList.toggle("sel", +r.dataset.i === F.sel));
  $("f-list").querySelector(".fr.sel")?.scrollIntoView({ block: "nearest" });
}
// ↵ acts on the results for what's typed now; if they're still on their way, it waits for them (up to 3 s)
async function findEnter(mode) {
  const q = $("f-q").value.trim(), gone = () => typeof findGone === "function" && findGone();
  if (q !== F.q) { clearTimeout(F.t); findRun(); }
  for (let i = 0; i < 60 && F.drawnQ !== q && !gone(); i++) await wait(50);
  if (F.drawnQ !== q || gone() || $("f-q").value.trim() !== q) return;
  const k = F.items[F.sel]; if (k) findGo(k, mode);
}
$("f-q").addEventListener("input", () => { clearTimeout(F.t); F.t = setTimeout(findRun, 70); });
$("f-q").addEventListener("keydown", e => {
  if (e.key === "ArrowDown") { e.preventDefault(); findMove(1); }
  else if (e.key === "ArrowUp") { e.preventDefault(); findMove(-1); }
  else if (e.key === "Enter") { e.preventDefault(); findEnter(findMode(e)); }
  else if (e.key === "Escape") { e.preventDefault(); findClose(); }
});
$("f-list").addEventListener("mousemove", e => { const r = e.target.closest(".fr"); if (r && +r.dataset.i !== F.sel) { F.sel = +r.dataset.i; findMove(0); } });
$("f-list").addEventListener("click", e => { const r = e.target.closest(".fr"); if (r) findGo(F.items[+r.dataset.i], e.target.closest(".ffind") ? "finder" : findMode(e)); });
