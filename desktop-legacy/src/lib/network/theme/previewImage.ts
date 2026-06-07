/**
 * Demo-only preview-image generator. Returns a data-URL SVG that looks
 * like a plausible workbook-as-webpage snapshot (browser-chrome strip
 * + page header + chart area) deterministically derived from a seed.
 *
 * In production, the desktop generates real snapshots locally at
 * publish time (headless render → screenshot → embed in the workbook
 * payload). This function exists ONLY to keep the demo design space
 * full while the real pipeline is unimplemented.
 */

function hash(s: string): number {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
  return Math.abs(h);
}

function mulberry(seed: number): () => number {
  let a = seed;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function generatePreviewSvg(seed: string): string {
  const h = hash(seed);
  const rand = mulberry(h);
  const hue = h % 360;
  const w = 800;
  const ht = 500;

  // Browser-chrome strip at the very top
  const chromeH = 26;
  // Page hero area below chrome
  const heroTop = chromeH + 18;
  const heroH = 72;
  // Chart area below the hero
  const chartTop = heroTop + heroH + 24;
  const chartBot = ht - 36;
  const chartH = chartBot - chartTop;

  const barCount = 8 + Math.floor(rand() * 6);
  const gap = 12;
  const padX = 56;
  const avail = w - padX * 2 - gap * (barCount - 1);
  const bw = avail / barCount;

  let bars = "";
  const heights: number[] = [];
  for (let i = 0; i < barCount; i++) {
    const r = 0.25 + rand() * 0.75;
    const bh = Math.max(14, Math.round(chartH * r));
    heights.push(bh);
    const x = padX + i * (bw + gap);
    const y = chartBot - bh;
    bars += `<rect x="${x.toFixed(1)}" y="${y.toFixed(1)}" width="${bw.toFixed(1)}" height="${bh}" rx="4" fill="hsl(${hue} 55% 50% / 0.55)"/>`;
  }
  // Overlay sparkline that traces above the bars
  let line = "";
  for (let i = 0; i < barCount; i++) {
    const x = padX + i * (bw + gap) + bw / 2;
    const y = chartBot - heights[i] - (8 + rand() * 18);
    line += (i === 0 ? "M" : "L") + ` ${x.toFixed(1)} ${y.toFixed(1)} `;
  }
  // Faint horizontal grid lines
  let grid = "";
  for (let g = 1; g <= 3; g++) {
    const y = chartTop + (chartH / 4) * g;
    grid += `<line x1="${padX}" y1="${y.toFixed(1)}" x2="${w - padX}" y2="${y.toFixed(1)}" stroke="hsl(${hue} 25% 35% / 0.12)" stroke-width="1"/>`;
  }

  // Page header (kicker + title + paragraph stub + meta row)
  const titleW = 220 + Math.floor(rand() * 140);
  const subW = 140 + Math.floor(rand() * 80);

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${ht}" width="${w}" height="${ht}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="hsl(${hue} 50% 96%)"/>
      <stop offset="100%" stop-color="hsl(${(hue + 40) % 360} 40% 92%)"/>
    </linearGradient>
  </defs>
  <rect width="${w}" height="${ht}" fill="url(#bg)"/>

  <!-- Browser chrome strip -->
  <rect x="0" y="0" width="${w}" height="${chromeH}" fill="hsl(${hue} 18% 88%)"/>
  <circle cx="14" cy="${chromeH / 2}" r="4" fill="hsl(${hue} 20% 70%)"/>
  <circle cx="28" cy="${chromeH / 2}" r="4" fill="hsl(${hue} 20% 70%)"/>
  <circle cx="42" cy="${chromeH / 2}" r="4" fill="hsl(${hue} 20% 70%)"/>
  <rect x="64" y="${chromeH / 2 - 6}" width="${Math.min(380, w - 80)}" height="12" rx="6" fill="hsl(${hue} 18% 78%)"/>

  <!-- Page header -->
  <rect x="${padX}" y="${heroTop}" width="60" height="8" rx="2.5" fill="hsl(${hue} 60% 45% / 0.7)"/>
  <rect x="${padX}" y="${heroTop + 16}" width="${titleW}" height="18" rx="4" fill="hsl(${hue} 35% 25% / 0.78)"/>
  <rect x="${padX}" y="${heroTop + 44}" width="${subW}" height="9" rx="3" fill="hsl(${hue} 25% 35% / 0.42)"/>
  <rect x="${padX + subW + 12}" y="${heroTop + 44}" width="78" height="9" rx="3" fill="hsl(${hue} 25% 35% / 0.28)"/>

  <!-- Chart -->
  ${grid}
  ${bars}
  <path d="${line}" fill="none" stroke="hsl(${hue} 55% 35% / 0.78)" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>

  <!-- Footer caption -->
  <rect x="${padX}" y="${ht - 22}" width="160" height="7" rx="2" fill="hsl(${hue} 20% 35% / 0.32)"/>
</svg>`;

  return `data:image/svg+xml;utf8,${encodeURIComponent(svg)}`;
}
