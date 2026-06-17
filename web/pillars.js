/* The Workbooks Browser — a force-directed node map.
   One Workbooks hub at center; three clusters group around it, each its own
   pillar of the same place: BUILD (any agent), SHARE (your team), DEPLOY
   (anywhere). Big colored brand logos + real teammate headshots. */
(function () {
  const svg = document.getElementById("pillarGraph");
  if (!svg || !window.d3) return;

  const NS = "http://www.w3.org/2000/svg";
  const W = 820, H = 640, cx = W / 2, cy = H / 2;

  const LOBE = "https://cdn.jsdelivr.net/npm/@lobehub/icons-static-svg/icons/";
  const DEV = "https://cdn.jsdelivr.net/gh/devicons/devicon/icons/";
  const FACE = "https://randomuser.me/api/portraits/";

  // order: build (top), share (lower-left), deploy (lower-right)
  const clusters = [
    { id: "build", label: "build", sub: "with any agent", color: "#aee5c2", kind: "logo",
      imgs: ["claude-color", "openai", "gemini-color", "mistral-color", "deepseek-color", "grok", "perplexity-color"].map(s => LOBE + s + ".svg") },
    { id: "share", label: "share", sub: "with your team", color: "#a8d4f0", kind: "face",
      imgs: [["women", 44], ["men", 32], ["women", 68], ["men", 75], ["women", 90], ["men", 54]].map(([g, n]) => FACE + g + "/" + n + ".jpg") },
    { id: "deploy", label: "deploy", sub: "anywhere", color: "#f3c5a3", kind: "logo",
      imgs: ["chrome/chrome-original", "android/android-original", "apple/apple-original", "firefox/firefox-original", "windows11/windows11-original", "linux/linux-original"].map(s => DEV + s + ".svg") },
  ];

  const ang = [-Math.PI / 2, (Math.PI * 5) / 6, Math.PI / 6], R = 198;
  const LEAF = 30, HUB = 58;
  const nodes = [{ id: "hub", type: "hub", r: HUB, fx: cx, fy: cy }];
  const links = [];
  clusters.forEach((c, ci) => {
    const ax = cx + Math.cos(ang[ci]) * R, ay = cy + Math.sin(ang[ci]) * R;
    nodes.push({ id: "a" + ci, type: "anchor", r: 6, cluster: ci, label: c.label, sub: c.sub, color: c.color, x: ax, y: ay });
    links.push({ source: "hub", target: "a" + ci, kind: "spine" });
    c.imgs.forEach((u, i) => {
      nodes.push({ id: c.id + i, type: "leaf", r: LEAF, cluster: ci, color: c.color, kind: c.kind, img: u,
        x: ax + (Math.random() - 0.5) * 80, y: ay + (Math.random() - 0.5) * 80 });
      links.push({ source: "a" + ci, target: c.id + i, kind: "leaf", color: c.color });
    });
  });

  // ── scaffold ──
  const defs = document.createElementNS(NS, "defs");
  defs.innerHTML =
    '<clipPath id="pgLeaf"><circle r="' + LEAF + '"/></clipPath>' +
    '<filter id="pgGlow" x="-70%" y="-70%" width="240%" height="240%"><feGaussianBlur stdDeviation="9" result="b"/><feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>';
  svg.appendChild(defs);
  const gLinks = document.createElementNS(NS, "g");
  const gNodes = document.createElementNS(NS, "g");
  const gLabels = document.createElementNS(NS, "g");
  svg.append(gLinks, gNodes, gLabels);

  const linkEls = links.map(l => {
    const e = document.createElementNS(NS, "line");
    e.setAttribute("stroke", l.kind === "spine" ? "rgba(255,255,255,.34)" : l.color);
    e.setAttribute("stroke-opacity", l.kind === "spine" ? "1" : "0.4");
    e.setAttribute("stroke-width", l.kind === "spine" ? "1.8" : "1.3");
    gLinks.appendChild(e);
    return e;
  });

  // labels: white text on a dark pill with a pastel dot — readable, not "colored heading"
  const labelEls = nodes.filter(n => n.type === "anchor").map(n => {
    const g = document.createElementNS(NS, "g");
    const r = document.createElementNS(NS, "rect");
    r.setAttribute("class", "pg-labelbg"); r.setAttribute("rx", "13");
    r.setAttribute("stroke", n.color); r.setAttribute("stroke-opacity", ".5");
    const dot = document.createElementNS(NS, "circle");
    dot.setAttribute("r", "4"); dot.setAttribute("fill", n.color);
    const t = document.createElementNS(NS, "text");
    t.setAttribute("class", "pg-label"); t.setAttribute("dominant-baseline", "central"); t.setAttribute("fill", "#f4f3ee");
    t.textContent = n.label;
    const sub = document.createElementNS(NS, "text");
    sub.setAttribute("class", "pg-sub"); sub.setAttribute("dominant-baseline", "central"); sub.setAttribute("fill", "#9aa0a6");
    sub.textContent = n.sub;
    g.append(r, dot, t, sub);
    gLabels.appendChild(g);
    return { n, g, r, dot, t, sub };
  });
  requestAnimationFrame(() => labelEls.forEach(o => {
    const tb = o.t.getBBox(), sb = o.sub.getBBox();
    const w = 18 + tb.width + 12 + sb.width + 16, h = 30;
    o.r.setAttribute("x", -w / 2); o.r.setAttribute("y", -h / 2); o.r.setAttribute("width", w); o.r.setAttribute("height", h);
    o.dot.setAttribute("cx", -w / 2 + 16); o.dot.setAttribute("cy", 0);
    o.t.setAttribute("x", -w / 2 + 28); o.t.setAttribute("text-anchor", "start");
    o.sub.setAttribute("x", w / 2 - 16); o.sub.setAttribute("text-anchor", "end");
    o._w = w;
  }));

  const petal = document.querySelector(".brandlock svg path");
  const petalD = petal && petal.getAttribute("d");

  nodes.forEach(n => {
    if (n.type === "anchor") return;
    const g = document.createElementNS(NS, "g");
    n._g = g; gNodes.appendChild(g);
    const ring = document.createElementNS(NS, "circle");
    ring.setAttribute("r", n.r);
    ring.setAttribute("fill", "#f7f6f1");
    ring.setAttribute("stroke", n.type === "hub" ? "#13d943" : n.color);
    ring.setAttribute("stroke-width", n.type === "hub" ? 3.5 : 3.5);
    if (n.type === "hub") ring.setAttribute("filter", "url(#pgGlow)");
    g.appendChild(ring);
    if (n.type === "hub" && petalD) {
      const wrap = document.createElementNS(NS, "g");
      wrap.setAttribute("transform", "translate(-36,-21) scale(.64)");
      const p = document.createElementNS(NS, "path");
      p.setAttribute("d", petalD); p.setAttribute("fill", "#121316");
      wrap.appendChild(p); g.appendChild(wrap);
    } else if (n.type === "leaf") {
      const im = document.createElementNS(NS, "image");
      im.setAttributeNS("http://www.w3.org/1999/xlink", "href", n.img);
      im.setAttribute("href", n.img);
      const cover = n.kind === "face";
      const s = cover ? n.r * 2 : n.r * 1.42;       // photos fill the circle; logos sit with padding
      im.setAttribute("x", -s / 2); im.setAttribute("y", -s / 2);
      im.setAttribute("width", s); im.setAttribute("height", s);
      im.setAttribute("clip-path", "url(#pgLeaf)");
      im.setAttribute("preserveAspectRatio", cover ? "xMidYMid slice" : "xMidYMid meet");
      g.appendChild(im);
    }
  });

  // ── simulation ──
  const sim = d3.forceSimulation(nodes)
    .force("link", d3.forceLink(links).id(d => d.id)
      .distance(l => (l.kind === "spine" ? 178 : 64))
      .strength(l => (l.kind === "spine" ? 0.2 : 0.5)))
    .force("charge", d3.forceManyBody().strength(-300))
    .force("collide", d3.forceCollide(d => d.r + 6).strength(0.95))
    .force("cx", d3.forceX(cx).strength(0.014))
    .force("cy", d3.forceY(cy).strength(0.014))
    .velocityDecay(0.8)
    .on("tick", tick);

  let t0 = 0;
  sim.force("wander", () => {
    t0 += 0.016;
    for (let i = 0; i < nodes.length; i++) {
      const n = nodes[i];
      if (n.type !== "leaf" || n.fx != null) continue;
      n.vx += Math.cos(t0 * 0.45 + i * 1.7) * 0.02;
      n.vy += Math.sin(t0 * 0.4 + i * 2.3) * 0.02;
    }
  });
  sim.alphaTarget(0.04).restart();

  function tick() {
    for (let i = 0; i < linkEls.length; i++) {
      const l = links[i], e = linkEls[i];
      e.setAttribute("x1", l.source.x); e.setAttribute("y1", l.source.y);
      e.setAttribute("x2", l.target.x); e.setAttribute("y2", l.target.y);
    }
    for (const n of nodes) if (n._g) n._g.setAttribute("transform", "translate(" + n.x + "," + n.y + ")");
    for (const { n, g } of labelEls) {
      const dy = n.y >= cy ? 104 : -104;
      g.setAttribute("transform", "translate(" + n.x + "," + (n.y + dy) + ")");
    }
  }

  // ── drag ──
  const drag = d3.drag()
    .container(() => svg)
    .subject((ev) => {
      let best = null, bd = Infinity;
      for (const n of nodes) {
        if (!n._g) continue;
        const dx = n.x - ev.x, dy = n.y - ev.y, d2 = dx * dx + dy * dy;
        if (d2 < bd && d2 < (n.r + 8) * (n.r + 8)) { bd = d2; best = n; }
      }
      return best;
    })
    .on("start", (ev) => { if (ev.subject) { sim.alphaTarget(0.3).restart(); ev.subject.fx = ev.subject.x; ev.subject.fy = ev.subject.y; } })
    .on("drag", (ev) => { if (ev.subject) { ev.subject.fx = ev.x; ev.subject.fy = ev.y; } })
    .on("end", (ev) => { if (ev.subject && ev.subject.type !== "hub") { sim.alphaTarget(0.04); ev.subject.fx = null; ev.subject.fy = null; } });
  d3.select(svg).call(drag);
})();
