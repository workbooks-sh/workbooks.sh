// Workbooks lander — behavior. Three parts: theme toggle (persisted +
// prefers-color-scheme), the theme-aware ASCII field (the machine "thinking"
// texture; throttled, viewport-paused, static under reduced-motion), and the
// live invoice demo that proves "describe it, watch it get built."

const root = document.documentElement;
const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
const $ = (s, r = document) => r.querySelector(s);

/* ── theme ─────────────────────────────────────────────────────────── */
const saved = localStorage.getItem("wb-theme");
if (saved) root.dataset.theme = saved;
else if (matchMedia("(prefers-color-scheme: dark)").matches) root.dataset.theme = "dark";

const label = $("#toggle-label");
const syncLabel = () => { if (label) label.textContent = root.dataset.theme === "dark" ? "light" : "dark"; };
syncLabel();
$("#toggle")?.addEventListener("click", () => {
  root.dataset.theme = root.dataset.theme === "dark" ? "light" : "dark";
  localStorage.setItem("wb-theme", root.dataset.theme);
  syncLabel();
  dispatchEvent(new Event("wb-theme"));
});

/* ── ASCII field ───────────────────────────────────────────────────── */
const RAMP = " ·:-=+*o#%@";
const hex = h => { const n = parseInt(h.slice(1), 16); return [n >> 16 & 255, n >> 8 & 255, n & 255]; };
// raw trio glows on dark; on light it washes out — readable variants instead
const PALETTES = {
  dark:  { trio: ["#00ff44", "#0080ff", "#ff0066"], gb: ["#00ff44", "#0080ff"] },
  light: { trio: ["#0a7a2a", "#0064d6", "#d60055"], gb: ["#0a7a2a", "#0064d6"] },
};
const mix = (stops, t) => {
  const seg = (stops.length - 1) * Math.min(.999, Math.max(0, t));
  const i = Math.floor(seg), f = seg - i, a = stops[i], b = stops[i + 1] || stops[i];
  return `rgb(${a[0] + (b[0] - a[0]) * f | 0},${a[1] + (b[1] - a[1]) * f | 0},${a[2] + (b[2] - a[2]) * f | 0})`;
};

function ascii(canvas) {
  const ctx = canvas.getContext("2d", { alpha: true });
  const dense = canvas.dataset.dense !== undefined;
  const speed = parseFloat(canvas.dataset.speed || "1");
  const cw = 9, ch = 15, dpr = Math.min(2, devicePixelRatio || 1);
  let cols, rows, stops, skip;

  function theme() {
    const dark = root.dataset.theme === "dark";
    const pal = PALETTES[dark ? "dark" : "light"][canvas.dataset.palette || "trio"];
    stops = pal.map(hex);
    skip = dark ? (dense ? 0.22 : 0.38) : (dense ? 0.34 : 0.5);
  }
  function resize() {
    const r = canvas.getBoundingClientRect();
    cols = Math.max(8, Math.floor(r.width / cw));
    rows = Math.max(4, Math.floor(r.height / ch));
    canvas.width = r.width * dpr;
    canvas.height = r.height * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.font = "13px 'Spline Sans Mono', monospace";
    ctx.textBaseline = "top";
  }
  function draw(t) {
    ctx.clearRect(0, 0, canvas.width / dpr, canvas.height / dpr);
    const time = t * 0.001 * speed;
    for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) {
      const v = (Math.sin(x * .28 + time) + Math.sin(y * .22 - time * 1.2) + Math.sin((x + y) * .16 + time * .8)
        + Math.sin(Math.hypot(x - cols / 2, y - rows / 2) * .3 - time * 1.4)) / 4;
      const n = (v + 1) / 2;
      const chr = RAMP[Math.floor(n * (RAMP.length - 1))];
      if (chr === " " || n < skip) continue;
      ctx.fillStyle = mix(stops, n);
      ctx.fillText(chr, x * cw, y * ch);
    }
  }

  theme(); resize();
  addEventListener("wb-theme", () => { theme(); if (reduceMotion) draw(1000); });
  if (reduceMotion) { draw(1000); return; }
  let raf, running = false, last = 0;
  const loop = t => { if (t - last >= 50) { draw(t); last = t; } raf = requestAnimationFrame(loop); };
  new IntersectionObserver(es => es.forEach(e => {
    if (e.isIntersecting && !running) { running = true; raf = requestAnimationFrame(loop); }
    else if (!e.isIntersecting && running) { running = false; cancelAnimationFrame(raf); }
  })).observe(canvas);
  let rz;
  addEventListener("resize", () => { clearTimeout(rz); rz = setTimeout(resize, 150); });
}
document.querySelectorAll("canvas.ascii").forEach(ascii);

/* ── live invoice demo ─────────────────────────────────────────────── */
const list = $("#list"), total = $("#total");
if (list && total) {
  const money = n => "$" + n.toLocaleString("en-US");
  const recompute = () => {
    let owed = 0;
    list.querySelectorAll(".lrow").forEach(r => { if (r.dataset.paid !== "true") owed += +r.dataset.amt; });
    total.textContent = money(owed);
  };
  list.addEventListener("click", e => {
    const b = e.target.closest(".pay");
    if (!b) return;
    const r = b.closest(".lrow");
    r.dataset.paid = "true";
    b.textContent = "Paid";
    recompute();
  });
  const NEW = [["Cedar & Co.", 1800], ["Bright Harbor", 2600], ["Atlas Works", 1400], ["Quill Design", 3000]];
  let i = 0;
  $("#add")?.addEventListener("click", () => {
    const [who, amt] = NEW[i++ % NEW.length];
    const r = document.createElement("div");
    r.className = "lrow";
    r.dataset.amt = amt;
    r.dataset.paid = "false";
    r.innerHTML = `<span class="who"></span><span class="amt"></span><button class="pay" type="button">Mark paid</button>`;
    r.querySelector(".who").textContent = who;
    r.querySelector(".amt").textContent = money(amt);
    list.appendChild(r);
    recompute();
  });
  recompute();
}

/* copy button */
document.querySelectorAll(".copy").forEach(b => b.addEventListener("click", async () => {
  await navigator.clipboard.writeText(b.dataset.copy);
  b.textContent = "copied";
  setTimeout(() => b.textContent = "copy", 1200);
}));
