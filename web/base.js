// Rumi — helpers shared by the app's page (index.html) and the menu-bar search panel (quick.html):
// formatting, names, the API, cartridge thumbnails and the instant hover hint.
const CAT = {
  video: "Video", image: "Photos", audio: "Audio", docs: "Documents", archive: "Archives",
  dev: "Developer", app: "Apps", cache: "Caches", other: "Other",
};
const THUMB_EXT = new Set("jpg jpeg png gif heic heif webp tif tiff psd dng cr2 cr3 nef arw bmp svg mp4 mov m4v mkv avi webm pdf key pages numbers ai sketch".split(" "));
const PHOTO_EXT = new Set("jpg jpeg png gif heic heif webp tif tiff psd dng cr2 cr3 nef arw bmp mp4 mov m4v mkv avi webm".split(" "));
// colour tokens are read once per task (one map draw asks for hundreds), then read fresh next time
const cssCache = new Map();
function css(v) {
  if (!cssCache.size) queueMicrotask(() => cssCache.clear());
  let x = cssCache.get(v);
  if (x === undefined) { x = getComputedStyle(document.documentElement).getPropertyValue(v).trim(); cssCache.set(v, x); }
  return x;
}
const color = c => css("--c-" + (CAT[c] ? c : "other"));
const $ = id => document.getElementById(id);
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const wait = ms => new Promise(r => setTimeout(r, ms));
// overlays fade in by CSS; hide() lets them fade out before they go
function show(id) { $("hint").hidden = true; const el = $(id); clearTimeout(el._t); el.classList.remove("closing"); el.hidden = false; }
function hide(id) {
  const el = $(id); $("hint").hidden = true; if (el.hidden || el.classList.contains("closing")) return;
  el.classList.add("closing"); el._t = setTimeout(() => { el.hidden = true; el.classList.remove("closing"); }, 160);
}

const params = new URLSearchParams(location.search);
let TOKEN = params.get("t") || sessionStorage.getItem("sm-token") || "";
if (params.get("t")) { sessionStorage.setItem("sm-token", TOKEN); const u = new URL(location.href); u.searchParams.delete("t"); history.replaceState(null, "", u.pathname + u.search + u.hash); }
const NATIVE = window.webkit?.messageHandlers?.rumi;   // set when running inside the Rumi Mac app
async function api(path, body) {
  if (body && NATIVE) return NATIVE.postMessage({ path, body });
  const r = await fetch(path, body ? { method: "POST", headers: { "X-Token": TOKEN, "Content-Type": "application/json" }, body: JSON.stringify(body) }
                                   : { headers: { "X-Token": TOKEN } });
  if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || r.status);
  return r.json();
}

function fmt(b, parts) {
  if (b == null) return "";
  const u = ["B", "KB", "MB", "GB", "TB"]; let i = 0;
  while (b >= 1000 && i < u.length - 1) { b /= 1000; i++; }
  const n = i >= 3 ? b.toFixed(b < 10 ? 2 : 1) : String(Math.round(b));
  return parts ? [n, u[i]] : n + " " + u[i];
}
function ago(t) {
  if (!t) return "";
  const d = (Date.now() / 1000 - t) / 86400;
  if (d < 1) return "today"; if (d < 2) return "yesterday"; if (d < 45) return Math.round(d) + " days ago";
  if (d < 600) return Math.round(d / 30) + " months ago"; return (d / 365).toFixed(1) + " years ago";
}
let HOME = "";
let BIN = "Trash";   // what this Mac calls the Trash ("Bin" in British English and its relatives); set from the app's status
const tilde = p => HOME && p && p.startsWith(HOME) ? "~" + p.slice(HOME.length) : p;
const base = p => (p || "").split("/").filter(Boolean).pop() || p;
// the folder something sits in, by name ("Downloads"); the full path is always in the hover hint
const whereOf = p => { const d = (p || "").slice(0, (p || "").lastIndexOf("/")); return d === HOME ? "Home" : (base(d) || "/").replace(/:/g, "/"); };   // Finder shows ":" in a name as "/"
const ext = n => { const m = /\.([a-z0-9]{1,6})$/i.exec(n || ""); return m ? m[1].toLowerCase() : ""; };
const isApp = k => /\.app$/.test(k.name || k.path || "");
const canThumb = k => !!k.path && (isApp(k) || (k.type !== "dir" && THUMB_EXT.has(ext(k.name || k.path))));
const thumbURL = (p, s) => `/api/thumb?t=${encodeURIComponent(TOKEN)}&path=${encodeURIComponent(p)}${s ? `&s=${s}` : ""}`;
const rootName = n => n === HOME || n === "~" ? "Home" : n.startsWith("/") || n.startsWith("~/") ? (n.split("/").filter(Boolean).pop() || n) : n;
// Finder shows ":" in a file name as "/"
const label = k => k.name && (k.name.startsWith("/") || k.name === "~") ? rootName(k.name) : (isApp(k) ? k.name.replace(/\.app$/, "") : String(k.name ?? "").replace(/:/g, "/"));
const ICON = {
  folder: `<svg class="i" viewBox="0 0 16 16" style="width:17px;height:17px"><path d="M1.8 4.2c0-.7.5-1.2 1.2-1.2h3l1.4 1.6h5.6c.7 0 1.2.5 1.2 1.2v6.2c0 .7-.5 1.2-1.2 1.2H3c-.7 0-1.2-.5-1.2-1.2z"/></svg>`,
  finder: `<svg class="i" viewBox="0 0 16 16"><path d="M9.5 2.5h4v4M13.5 2.5 8 8M12 9.5v3c0 .6-.4 1-1 1H3.5c-.6 0-1-.4-1-1V5c0-.6.4-1 1-1h3"/></svg>`,
  open: `<svg class="i" viewBox="0 0 16 16"><path d="M6 3.5 10.5 8 6 12.5"/></svg>`,
  plus: `<svg class="i" viewBox="0 0 16 16" style="width:13px;height:13px;stroke-width:2.2"><path d="M8 3.5v9M3.5 8h9"/></svg>`,
  check: `<svg class="i" viewBox="0 0 16 16" style="width:13px;height:13px;stroke-width:2.2"><path d="M3.8 8.4 6.6 11 12.2 5"/></svg>`,
  back: `<svg class="i" viewBox="0 0 16 16"><path d="M10 3.5 5.5 8l4.5 4.5"/></svg>`,
  x: `<svg class="i" viewBox="0 0 16 16" style="width:12px;height:12px"><path d="M4.5 4.5l7 7M11.5 4.5l-7 7"/></svg>`,
  info: `<svg class="i" viewBox="0 0 16 16" style="width:13px;height:13px"><circle cx="8" cy="8" r="6"/><path d="M8 7.3v3.7M8 5.2v.1"/></svg>`,
  clock: `<svg class="i" viewBox="0 0 16 16" style="width:13px;height:13px"><circle cx="8" cy="8" r="6"/><path d="M8 4.6V8l2.3 1.5"/></svg>`,
  lock: `<svg class="i lk" viewBox="0 0 16 16"><rect x="3.5" y="7" width="9" height="6.5" rx="1.5"/><path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2"/></svg>`,
};

function tile(k, size) {
  const c = color(k.cat), e = ext(k.name || k.path);
  const lbl = k.type === "dir" && !isApp(k) ? ICON.folder : esc((e || "file").slice(0, 4).toUpperCase());
  if (canThumb(k)) return `<span class="tile withimg" style="--c:${c}">${lbl}<img class="${isApp(k) ? "app" : ""}" alt="" data-src="${thumbURL(k.path, 112)}" onload="this.classList.add('ok')" onerror="this.remove();this.parentNode&&this.parentNode.classList.remove('withimg')"></span>`;
  return `<span class="tile" style="--c:${c}">${lbl}</span>`;
}

/* ---------- thumbnail queue ----------
   Browsers allow ~6 requests at once per site and a new thumbnail takes ~0.7 s to make, so loading them all at once
   used to block the folder you just clicked. At most 3 load at a time, in on-screen order; ones no longer shown are skipped. */
const TQ = { q: [], n: 0, max: 3, hold: 0 };
function qThumb(img, front) { if (img.dataset.q) return; img.dataset.q = 1; front ? TQ.q.unshift(img) : TQ.q.push(img); pumpThumbs(); }
function pumpThumbs() {
  while (!TQ.hold && TQ.n < TQ.max && TQ.q.length) {
    const img = TQ.q.shift(); if (!img.isConnected || img.getAttribute("src")) continue;
    TQ.n++; let done = false; const fin = () => { if (done) return; done = true; TQ.n--; pumpThumbs(); };
    img.addEventListener("load", fin, { once: true }); img.addEventListener("error", fin, { once: true }); setTimeout(fin, 12000);
    img.src = img.dataset.src;
  }
}
new MutationObserver(ms => { for (const m of ms) for (const n of m.addedNodes) if (n.nodeType === 1) {
  const front = !!n.closest?.("#tip, #insp");
  if (n.matches("img[data-src]")) qThumb(n, front); n.querySelectorAll("img[data-src]").forEach(i => qThumb(i, front));
} }).observe(document.body, { childList: true, subtree: true });
// details live on hover: anything with data-tip shows a small hint at once (no delay), under it or above if there's no room
let hintEl = null;
document.addEventListener("mouseover", e => {
  const el = e.target.closest?.("[data-tip]"), h = $("hint");
  if (el === hintEl) return;
  hintEl = el;
  if (!el || !el.dataset.tip) { h.hidden = true; return; }
  h.textContent = el.dataset.tip; h.hidden = false;
  const r = el.getBoundingClientRect(), w = h.offsetWidth, ht = h.offsetHeight;
  // menu rows put the hint beside the menu, so it never covers the next row
  if (el.dataset.tipSide === "right" && r.right + 14 + w < innerWidth - 8) { h.style.left = r.right + 14 + "px"; h.style.top = r.top + r.height / 2 - ht / 2 + "px"; return; }
  const x = Math.min(Math.max(8, r.width > 240 ? r.left : r.left + r.width / 2 - w / 2), innerWidth - w - 8);
  const y = r.bottom + 6 + ht > innerHeight - 8 ? r.top - ht - 6 : r.bottom + 6;
  h.style.left = x + "px"; h.style.top = y + "px";
});
// the same hint for whatever the keyboard is on
document.addEventListener("focusin", e => { const el = e.target.closest?.("[data-tip]"); if (el && e.target.matches(":focus-visible")) el.dispatchEvent(new MouseEvent("mouseover", { bubbles: true })); else { $("hint").hidden = true; hintEl = null; } });
document.addEventListener("focusout", () => { $("hint").hidden = true; hintEl = null; });
const dropHint = () => { $("hint").hidden = true; hintEl = null; };
["mousedown", "keydown", "wheel"].forEach(t => addEventListener(t, dropHint, { capture: true, passive: true }));
