// Render scripts/icon.html to mac/AppIcon-1024.png with headless Chrome (run when the mascot changes; the PNG is committed).
import { spawn } from "node:child_process";
import { writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const port = 9600 + Math.floor(Math.random() * 40);
const chrome = spawn("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", ["--headless=new", "--hide-scrollbars", "--allow-file-access-from-files", `--remote-debugging-port=${port}`, `--user-data-dir=${mkdtempSync(join(tmpdir(), "rumi-icon-"))}`, "about:blank"], { stdio: "ignore" });
const sleep = ms => new Promise(r => setTimeout(r, ms));
let ws, id = 0; const pending = new Map();
const send = (method, params = {}) => new Promise(res => { const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params })); });
try {
  let t; for (let i = 0; i < 120 && !t; i++) { await sleep(250); try { t = (await (await fetch(`http://127.0.0.1:${port}/json`)).json()).find(x => x.type === "page"); } catch {} }
  ws = new WebSocket(t.webSocketDebuggerUrl); await new Promise(r => ws.onopen = r);
  ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); } };
  await send("Emulation.setDeviceMetricsOverride", { width: 1024, height: 1024, deviceScaleFactor: 1, mobile: false });
  await send("Emulation.setDefaultBackgroundColorOverride", { color: { r: 0, g: 0, b: 0, a: 0 } });
  await send("Page.navigate", { url: "file://" + join(root, "scripts/icon.html") }); await sleep(1200);
  const r = await send("Page.captureScreenshot", { format: "png", clip: { x: 0, y: 0, width: 1024, height: 1024, scale: 1 } });
  writeFileSync(join(root, "mac/AppIcon-1024.png"), Buffer.from(r.data, "base64"));
  console.log("✓ mac/AppIcon-1024.png");
} finally { ws?.close(); chrome.kill(); }
