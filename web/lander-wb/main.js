// Workbooks lander — base behavior: theme toggle, the ASCII texture, copy button.
// (No invoice demo — the real sample workbooks run live in their own tiles.)

const root = document.documentElement;
const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
const $ = (s, r = document) => r.querySelector(s);

/* ── theme ── */
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

/* ── ASCII texture (the machine "thinking" field; theme-aware, throttled) ── */
const RAMP = " ·:-=+*o#%@";
const hex = h => { const n = parseInt(h.slice(1), 16); return [n >> 16 & 255, n >> 8 & 255, n & 255]; };
const PALETTES = {
  dark:  [hex("#00ff44"), hex("#0080ff"), hex("#ff0066")],
  light: [hex("#0a7a2a"), hex("#0064d6"), hex("#d60055")],
};
const mix = (stops, t) => {
  const seg = t * (stops.length - 1), i = Math.min(stops.length - 2, Math.floor(seg)), f = seg - i;
  const a = stops[i], b = stops[i + 1];
  return [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f];
};
function ascii(canvas) {
  const ctx = canvas.getContext("2d", { alpha: true });
  const speed = parseFloat(canvas.dataset.speed || "0.7");
  let pal = PALETTES[root.dataset.theme === "dark" ? "dark" : "light"];
  const theme = () => { pal = PALETTES[root.dataset.theme === "dark" ? "dark" : "light"]; };
  let w, h, cols, rows, cw = 7, ch = 12, dpr = Math.min(2, devicePixelRatio || 1);
  function resize() {
    const r = canvas.getBoundingClientRect();
    w = r.width; h = r.height;
    canvas.width = w * dpr; canvas.height = h * dpr;
    cols = Math.ceil(w / cw); rows = Math.ceil(h / ch);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.font = "11px 'Spline Sans Mono', monospace"; ctx.textBaseline = "top";
  }
  function draw(t) {
    ctx.clearRect(0, 0, w, h);
    const T = t * 0.001 * speed;
    for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) {
      const v = (Math.sin(x * 0.18 + T) + Math.sin(y * 0.22 - T) + Math.sin((x + y) * 0.12 + T * 1.3)) / 3;
      const n = (v + 1) / 2;
      const ch2 = RAMP[Math.min(RAMP.length - 1, Math.floor(n * RAMP.length))];
      if (ch2 === " ") continue;
      const c = mix(pal, n);
      ctx.fillStyle = `rgb(${c[0]|0},${c[1]|0},${c[2]|0})`;
      ctx.fillText(ch2, x * cw, y * ch);
    }
  }
  let raf, last = 0, vis = true;
  const loop = t => { if (vis && t - last > 50) { draw(t); last = t; } raf = requestAnimationFrame(loop); };
  resize(); theme();
  if (reduceMotion) draw(1000);
  else raf = requestAnimationFrame(loop);
  addEventListener("wb-theme", () => { theme(); if (reduceMotion) draw(1000); });
  new IntersectionObserver(es => es.forEach(e => vis = e.isIntersecting)).observe(canvas);
  let rz; addEventListener("resize", () => { clearTimeout(rz); rz = setTimeout(resize, 150); });
}
document.querySelectorAll("canvas.ascii").forEach(ascii);

/* ── copy button ── */
document.querySelectorAll(".copy").forEach(b => b.addEventListener("click", async () => {
  try { await navigator.clipboard.writeText(b.dataset.copy); const t = b.textContent; b.textContent = "copied"; setTimeout(() => b.textContent = t, 1400); } catch (_) {}
}));
