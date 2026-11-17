// Rumi, the mascot: a purple cartridge whose label is a little dark screen with a glowing face ("Screen", picked Nov 9).
// Rumi.svg(mood, { size, simple }) returns markup; Rumi.mount(el, mood, opts) swaps it in with a screen power-on;
// Rumi.face(mood, width) is the face alone.
// Moods: idle, scan, wow, happy, sleep, empty, wink. All motion is CSS (styles.css › "Rumi the mascot").
(function () {
  const BODY = "#8a7fe6", SCREEN = "#231f36", GLOW = "#ff8fb3", SLEEPY = "#a99cf5", INK = "#18181b", LED = "#7ee2a8";
  const r1 = n => Math.round(n * 100) / 100;
  let uid = 0;

  // cartridge shell: big top corners, small bottom corners
  const shell = (x, y, w, h, rt, rb) =>
    `M${r1(x + rt)} ${y}H${r1(x + w - rt)}Q${x + w} ${y} ${x + w} ${r1(y + rt)}V${r1(y + h - rb)}Q${x + w} ${y + h} ${r1(x + w - rb)} ${y + h}H${r1(x + rb)}Q${x} ${y + h} ${x} ${r1(y + h - rb)}V${r1(y + rt)}Q${x} ${y} ${r1(x + rt)} ${y}Z`;
  function body(g, flat) {
    let s = `<path d="${shell(g.x, g.y, g.w, g.h, g.rt, g.rb)}" fill="${BODY}"/>`;
    if (!flat) {
      const sw = Math.max(3, g.w * .04);
      s += `<rect x="${g.x}" y="${g.y + g.rt}" width="${sw}" height="${g.h - g.rt - g.rb}" fill="#fff" opacity=".24"/>`
        + `<rect x="${g.x + g.w - sw}" y="${g.y + g.rt}" width="${sw}" height="${g.h - g.rt - g.rb}" fill="#000" opacity=".07"/>`
        + `<rect x="${g.x + g.rb}" y="${g.y + g.h - 3.2}" width="${g.w - 2 * g.rb}" height="3.2" fill="#000" opacity=".1"/>`;
    }
    return s;
  }
  const ridges = (cx, y, w, n) => { let s = ""; for (let i = 0; i < n; i++) s += `<rect x="${cx - w / 2}" y="${y + i * 4.4}" width="${w}" height="2" rx="1" fill="#000" opacity=".15"/>`; return s; };
  function teeth(x, y, w, h = 11) {
    let s = `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="2.5" fill="#000" opacity=".13"/>`;
    const n = Math.floor((w - 6) / 5.5), start = x + (w - (n * 5.5 - 2.9)) / 2;
    for (let i = 0; i < n; i++) s += `<rect x="${r1(start + i * 5.5)}" y="${y + 2.5}" width="2.6" height="${h - 5}" rx="1" fill="#000" opacity=".2"/>`;
    return s;
  }
  const star = (cx, cy, r, c) => `<path d="M${cx} ${cy - r}Q${cx} ${cy} ${cx + r} ${cy}Q${cx} ${cy} ${cx} ${cy + r}Q${cx} ${cy} ${cx - r} ${cy}Q${cx} ${cy} ${cx} ${cy - r}Z" fill="${c}"/>`;

  // the face, drawn in a 100×60 box and scaled onto the screen
  function face(e, box, G, glow) {
    const s = box.w / 100, ty = box.y + (box.h - 60 * s) / 2, k = G ? 1.42 : 1, sw = G ? 8 : 4.6, L = 33, R = 67;
    const eye = (cx, cy, rx, ry) => { rx *= k; ry *= k; return `<rect x="${r1(cx - rx)}" y="${r1(cy - ry)}" width="${r1(2 * rx)}" height="${r1(2 * ry)}" rx="${r1(rx * .5)}" fill="${glow}"/>`; };
    const st = (w = sw) => `fill="none" stroke="${glow}" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round"`;
    const arcUp = (cx, y = 28) => `<path d="M${cx - 8} ${y}Q${cx} ${y - 12} ${cx + 8} ${y}" ${st()}/>`;
    const eyes = (y = 25, rx = 6.4, ry = 8.4) => `<g class="r-eyes">${eye(L, y, rx, ry)}${eye(R, y, rx, ry)}</g>`;
    const smile = `<path d="M43 ${G ? 43 : 41}Q50 ${G ? 51 : 48} 57 ${G ? 43 : 41}" ${st()}/>`;
    let f = "";
    if (e === "idle") f = `<g class="r-wander">${eyes()}</g>${smile}`;
    if (e === "scan") f = `<g class="r-glance">${eyes()}</g><path d="M45 44H54" ${st()}/>`;
    if (e === "wow") f = `<path d="M${L - 8} 7Q${L} 1 ${L + 8} 5" ${st(3.6)}/><path d="M${R - 8} 5Q${R} 1 ${R + 8} 7" ${st(3.6)}/>`
      + eye(L, 25, 7.4, 9.6) + eye(R, 25, 7.4, 9.6) + `<rect x="45" y="40" width="10" height="11" rx="4" fill="${glow}"/>`;
    if (e === "happy") f = arcUp(L) + arcUp(R) + `<path d="M39 37Q50 39.5 61 37Q59 53 50 53Q41 53 39 37Z" fill="${glow}"/>`;
    if (e === "wink") f = arcUp(L) + `<g class="r-eyes">${eye(R, 25, 6.4, 8.4)}</g>` + `<path d="M41 40Q50 50 59 40" ${st()}/>`;
    if (e === "sleep") f = `<path d="M${L - 8} 25Q${L} 32 ${L + 8} 25" ${st()}/><path d="M${R - 8} 25Q${R} 32 ${R + 8} 25" ${st()}/>`
      + `<ellipse class="r-snore" cx="50" cy="45" rx="3.4" ry="3.8" fill="${glow}"/>`;
    if (e === "empty") f = `<g class="r-eyes">${eye(L, 30, 5.8, 7.4)}${eye(R, 30, 5.8, 7.4)}</g><path d="M40 47.5Q45 43.5 50 47.5Q55 51.5 60 47.5" ${st()}/>`;
    return `<g transform="translate(${r1(box.x)} ${r1(ty)}) scale(${r1(s * 1000) / 1000})"><g class="r-look">${f}</g></g>`;
  }

  // things that happen around Rumi
  function around(e, g) {
    const top = g.y, right = g.x + g.w, left = g.x;
    if (e === "wow") return `<g class="r-burst" fill="none" stroke="${INK}" stroke-width="4" stroke-linecap="round">
        <path d="M${right + 6} ${top + 14}L${right + 16} ${top + 6}"/><path d="M${right + 9} ${top + 28}L${right + 21} ${top + 26}"/><path d="M${right - 4} ${top + 2}L${right} ${top - 9}"/>
        <path d="M${left - 6} ${top + 14}L${left - 16} ${top + 6}"/><path d="M${left + 4} ${top + 2}L${left} ${top - 9}"/></g>`;
    if (e === "happy") return `<g class="r-pop">${star(right + 12, top + 10, 8, "#f3c14d")}</g><g class="r-pop b">${star(left - 10, top + 30, 6, BODY)}</g><g class="r-pop c">${star(right + 4, top + 44, 4.5, "#ec4f7c")}</g>`;
    if (e === "sleep") return `<text class="r-zz" x="${right + 4}" y="${top + 22}" font-size="16" font-weight="800" fill="${INK}" opacity=".5" font-family="M PLUS Rounded 1c, sans-serif">z</text>
        <text class="r-zz b" x="${right + 14}" y="${top + 6}" font-size="12" font-weight="800" fill="${INK}" opacity=".35" font-family="M PLUS Rounded 1c, sans-serif">z</text>`;
    if (e === "empty") return `<path class="r-tear" d="M${right + 9} ${top + 10}Q${right + 16} ${top + 19.5} ${right + 9} ${top + 23}Q${right + 2} ${top + 19.5} ${right + 9} ${top + 10}Z" fill="#8cc4f5"/>`;
    return "";
  }
  const lock = (cx, cy) => `<g class="r-lock"><circle cx="${cx}" cy="${cy + 2.5}" r="13" fill="#3c2814" opacity=".14"/><circle cx="${cx}" cy="${cy}" r="13" fill="#fff"/>
    <path d="M${cx - 4.2} ${cy - 1}V${cy - 4.5}a4.2 4.2 0 0 1 8.4 0V${cy - 1}" fill="none" stroke="#ec4f7c" stroke-width="2.6"/>
    <rect x="${cx - 6.5}" y="${cy - 1.5}" width="13" height="10" rx="2.6" fill="#ec4f7c"/><circle cx="${cx}" cy="${cy + 3.4}" r="1.6" fill="#fff"/></g>`;

  function draw(e, G, opt) {
    const g = { x: 28, y: 24, w: 104, h: 128, rt: 16, rb: 6 };
    const lb = G ? { x: g.x + 9, y: g.y + 16, w: g.w - 18, h: 82 } : { x: g.x + 11, y: g.y + 24, w: g.w - 22, h: 70 };
    const glow = e === "sleep" ? SLEEPY : GLOW, id = "rs" + (++uid);
    let a = body(g, G);
    if (!G) a += ridges(80, g.y + 7, 36, 3) + teeth(g.x + 18, g.y + g.h - 21, g.w - 36);
    a += `<rect x="${lb.x - 3}" y="${lb.y - 3}" width="${lb.w + 6}" height="${lb.h + 6}" rx="${G ? 12 : 10}" fill="#000" opacity=".16"/>`;
    a += `<rect x="${lb.x}" y="${lb.y}" width="${lb.w}" height="${lb.h}" rx="${G ? 10 : 8}" fill="${SCREEN}"/>`;
    // the screen's contents power on like a little CRT when the mood changes
    let scr = "";
    if (!G) {
      a += `<clipPath id="${id}"><rect x="${lb.x}" y="${lb.y}" width="${lb.w}" height="${lb.h}" rx="8"/></clipPath>`;
      for (let y = lb.y + 4; y < lb.y + lb.h - 2; y += 4) scr += `<rect x="${lb.x + 2}" y="${y}" width="${lb.w - 4}" height="1" fill="#fff" opacity=".035"/>`;
      scr += `<path d="M${lb.x + 6} ${lb.y + 4}H${lb.x + 30}" stroke="#fff" stroke-width="2" stroke-linecap="round" opacity=".14"/>`;
      if (e === "scan") scr += `<rect class="r-beam" x="${lb.x + 4}" y="${lb.y + 4}" width="${lb.w - 8}" height="3" rx="1.5" fill="${GLOW}" opacity=".3" style="--h:${lb.h - 11}px"/>`;
    }
    scr += face(e, { ...lb, y: lb.y + 3 }, G, glow);
    a += `<g class="r-screen" ${G ? "" : `clip-path="url(#${id})"`}>${scr}</g>`;
    if (!G) a += `<circle class="r-led" cx="${g.x + g.w - 17}" cy="${g.y + 106}" r="2.6" fill="${e === "sleep" ? "#f3c14d" : LED}"/>
        <text x="${g.x + 14}" y="${g.y + 109}" font-size="8" font-weight="800" letter-spacing="1.4" fill="#fff" opacity=".55" font-family="M PLUS Rounded 1c, sans-serif">RUMI</text>`;
    if (G) { const side = Math.max(g.w, g.h) + 8, cx = g.x + g.w / 2, cy = g.y + g.h / 2; return { vb: `${cx - side / 2} ${cy - side / 2} ${side} ${side}`, svg: `<g class="r-body">${a}</g>` }; }

    const lift = e === "happy" ? -10 : 0, by = g.y + g.h + 4, bx = g.x + g.w / 2;
    // standing: a crisp drop under the shell; hopping: a soft spot on the ground
    const shadow = lift ? `<ellipse class="r-spot" cx="${bx}" cy="${by - 1}" rx="40" ry="4.5" fill="#3c2814" opacity=".1"/>`
      : `<path class="r-shadow" d="${shell(g.x, g.y + 5, g.w, g.h, g.rt, g.rb)}" fill="#3c2814" opacity=".13"/>`;
    const puff = (x, d) => `<circle cx="${x}" cy="${by}" r="6" fill="#ebe6dc"/><circle cx="${x + d * 8}" cy="${by - 3}" r="4.5" fill="#ebe6dc"/><circle cx="${x + d * 14}" cy="${by + 1}" r="3" fill="#ebe6dc"/>`;
    const puffs = lift ? `<g class="r-puffs">${puff(bx - 46, -1)}${puff(bx + 46, 1)}</g>` : "";
    const loop = { scan: "r-bob", happy: "r-float", sleep: "r-breathe", idle: "r-idle" }[e] || "";
    const once = { happy: "r-hop", wow: "r-jolt", wink: "r-nod" }[e] || "";
    const extra = e === "sleep" && opt.lock !== false ? lock(g.x + g.w - 4, g.y + g.h - 18) : "";
    return { vb: "0 0 160 180", svg: `${puffs}${lift ? shadow : ""}<g class="${once}">${lift ? "" : shadow}<g transform="translate(0 ${lift})"><g class="r-body ${loop}">${a}</g></g></g>${around(e, g)}${extra}` };
  }

  function svg(mood = "idle", opt = {}) {
    const G = !!opt.simple, r = draw(mood, G, opt), [, , vw, vh] = r.vb.split(" ").map(Number);
    const w = opt.size || 120, h = Math.round(w * vh / vw);
    // each Rumi blinks on its own clock
    const lag = (-(uid * 1.7) % 5.2).toFixed(2);
    return `<svg class="rumi r-${mood}${G ? " r-simple" : ""}" viewBox="${r.vb}" width="${w}" height="${h}" style="--lag:${lag}s" aria-hidden="true">${r.svg}</svg>`;
  }
  function mount(el, mood, opt = {}) {
    if (!el) return;
    const key = mood + "|" + JSON.stringify(opt);
    if (el.dataset.rumi === key) return;
    const first = !el.dataset.rumi; el.dataset.rumi = key;
    el.innerHTML = svg(mood, opt);
    if (!first || opt.powerOn) el.firstElementChild.classList.add("r-on");
  }
  // just the face, in the colour of the text around it: for a screen bigger than Rumi's own (the Bin screen)
  function faceOnly(mood = "idle", w = 84) {
    return `<svg class="rumi r-${mood}" viewBox="0 0 100 60" width="${w}" height="${Math.round(w * .6)}" style="--lag:${(-(++uid * 1.7) % 5.2).toFixed(2)}s" aria-hidden="true">${face(mood, { x: 0, y: 0, w: 100, h: 60 }, false, "currentColor")}</svg>`;
  }
  window.Rumi = { svg, mount, face: faceOnly };
})();
