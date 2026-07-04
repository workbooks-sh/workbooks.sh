/* autopoet.app hero graph — a living, evolving replica of the studio
   KnowledgeGraph: pastel typed nodes on paper, hairline structural edges,
   dashed violet semantic edges, force-directed drift. Fake data, real feel:
   six clusters anchored around the hero at different depths — hubs, members,
   and chains 3–4 deep — evolving as if the system underneath is thinking.
   The middle belongs to the hero: an elliptical keep-out no node may enter. */

(function () {
  const svg = document.getElementById("graph");
  if (!svg) return;

  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const COLORS = () => ({
    service: css("--fuchsia"), module: css("--sky"), flow: css("--peach"),
    data: css("--mint"), fn: css("--fg"), concept: css("--amber"),
    doc: css("--cream"), entity: css("--violet"), config: css("--fg-subtle"),
    edge: css("--edge"), semantic: css("--violet"), paper: css("--page"),
    ink: css("--fg"),
  });
  let C = COLORS();

  let W = innerWidth, H = innerHeight;
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  let uid = 0;

  // The hero owns the middle: a big elliptical keep-out around the center
  // text/buttons. All graph action happens in the ring outside it.
  let KX, KY;
  function sizeKeepOut() {
    KX = Math.min(Math.max(W * 0.33, 300), 560);
    KY = Math.min(Math.max(H * 0.38, 240), 400);
  }
  sizeKeepOut();

  const anchorOf = (angle, depth) => ({
    x: W / 2 + Math.cos(angle) * KX * depth,
    y: H / 2 + Math.sin(angle) * KY * depth,
  });

  // ---- fake-but-plausible system map: clusters with hubs, members, chains ----
  // angle: where the cluster lives around the ring; depth: how far out.
  const CLUSTERS = [
    { key: "core", angle: -1.35, depth: 1.5,
      hub: ["worker", "service"],
      members: [["gate", "fn"], ["lease", "fn"], ["eval", "fn"], ["scheduler", "module"], ["heartbeat", "flow"]],
      chains: [[["sense", "flow"], ["decide", "flow"], ["act", "flow"], ["learn", "flow"]]] },
    { key: "workspace", angle: -0.25, depth: 1.6,
      hub: ["index.work", "config"],
      members: [["ceiling", "config"], ["grants", "config"]],
      chains: [
        [["scout.work", "entity"], ["prompt", "doc"]],
        [["mailer.work", "entity"], ["templates", "doc"]],
        [["deploy.work", "entity"]],
        [["billing.work", "entity"], ["invoices", "data"]],
      ] },
    { key: "telemetry", angle: 0.85, depth: 1.45,
      hub: ["telemetry", "module"],
      members: [["concern", "concept"], ["cost", "data"]],
      chains: [
        [["predictor", "fn"], ["surprise", "concept"], ["drift", "concept"]],
        [["reflex", "fn"], ["handler", "fn"]],
      ] },
    { key: "events", angle: 2.1, depth: 1.55,
      hub: ["bus", "module"],
      members: [["hooks", "module"]],
      chains: [
        [["self_edit.requested", "concept"], ["request", "doc"]],
        [["plan.created", "concept"], ["handoff", "doc"]],
        [["escalation", "concept"], ["review", "doc"]],
      ] },
    { key: "knowledge", angle: 3.05, depth: 1.5,
      hub: ["knowledge", "data"],
      members: [["lesson", "doc"], ["recall", "fn"]],
      chains: [
        [["weights", "data"], ["hebb", "concept"]],
        [["ledger", "data"], ["credit", "concept"], ["wealth", "data"]],
      ] },
    { key: "scratch", angle: 4.0, depth: 1.6,
      hub: ["scratch", "doc"],
      members: [["parse", "fn"], ["purity", "fn"], ["authority", "fn"]],
      chains: [[["merge-lane", "flow"], ["hot-reload", "flow"]]] },
  ];
  // cross-cluster spine: worker reaches every hub (long, mostly dashed)
  const CROSS = [
    ["worker", "telemetry", true], ["worker", "bus", true], ["worker", "knowledge", false],
    ["worker", "scratch", false], ["worker", "index.work", true],
    ["gate", "ceiling", true], ["eval", "scratch", false], ["learn", "knowledge", true],
    ["drift", "concern", false], ["escalation", "review", false],
  ];
  const EPHEMERAL = [
    ["grant +net", "config"], ["proposal", "doc"], ["replay", "data"], ["trace", "data"],
    ["surprise!", "concept"], ["viseme", "fn"], ["cortex", "service"], ["genome", "data"],
    ["notes.work", "entity"], ["intake", "flow"], ["snapshot", "data"], ["shadow", "service"],
    ["budget", "config"], ["tripwire", "concept"], ["ablation", "fn"], ["mood", "concept"],
  ];

  function mkNode(name, type, cluster, role, x, y) {
    const cl = CLUSTERS.find((c) => c.key === cluster);
    const home = cl ? anchorOf(cl.angle, cl.depth) : anchorOf(Math.random() * 6.28, 1.4);
    return {
      id: uid++, name, type, cluster, role,
      x: x ?? home.x + (Math.random() - 0.5) * 140,
      y: y ?? home.y + (Math.random() - 0.5) * 140,
      vx: 0, vy: 0, born: performance.now(), dying: 0, pulse: 0, fixed: false,
    };
  }

  let nodes = [], links = [];
  const byName = (name) => nodes.find((n) => n.name === name);

  for (const cl of CLUSTERS) {
    const hub = mkNode(cl.hub[0], cl.hub[1], cl.key, "hub");
    nodes.push(hub);
    for (const [name, type] of cl.members) {
      const m = mkNode(name, type, cl.key, "member");
      nodes.push(m);
      links.push({ s: hub, t: m, semantic: false, kind: "member", flash: 0 });
    }
    for (const chain of cl.chains) {
      let prev = hub;
      chain.forEach(([name, type], i) => {
        const n = mkNode(name, type, cl.key, i === chain.length - 1 ? "leaf" : "chain");
        nodes.push(n);
        links.push({ s: prev, t: n, semantic: false, kind: "chain", flash: 0 });
        prev = n;
      });
    }
  }
  for (const [a, b, dashed] of CROSS) {
    const s = byName(a), t = byName(b);
    if (s && t) links.push({ s, t, semantic: dashed, kind: "cross", flash: 0 });
  }

  // ---- render skeleton ----
  const NS = "http://www.w3.org/2000/svg";
  const edgeLayer = document.createElementNS(NS, "g");
  const nodeLayer = document.createElementNS(NS, "g");
  svg.appendChild(edgeLayer); svg.appendChild(nodeLayer);

  const R = { hub: 9.5, member: 7, chain: 6, leaf: 5 };
  const baseR = (n) => R[n.role] || 6;

  function el(node) {
    const g = document.createElementNS(NS, "g");
    const c = document.createElementNS(NS, "circle");
    c.setAttribute("stroke-width", "1.5");
    const t = document.createElementNS(NS, "text");
    t.setAttribute("x", String(baseR(node) + 4)); t.setAttribute("y", "4");
    t.setAttribute("font-size", node.role === "hub" ? "11.5" : node.role === "leaf" ? "10" : "11");
    t.textContent = node.name;
    g.appendChild(c); g.appendChild(t);
    nodeLayer.appendChild(g);
    node._g = g; node._c = c; node._t = t;
    paintNode(node);
    return g;
  }
  function lel(link) {
    // cross-cluster edges are curved paths that bow AROUND the hero's
    // keep-out; everything else is a straight hairline
    const l = document.createElementNS(NS, link.kind === "cross" ? "path" : "line");
    if (link.kind === "cross") l.setAttribute("fill", "none");
    edgeLayer.appendChild(l);
    link._l = l;
    paintLink(link);
    return l;
  }
  function paintNode(n) {
    n._c.setAttribute("fill", C[n.type] || C.entity);
    n._c.setAttribute("stroke", C.paper);
    n._t.setAttribute("fill", C.ink);
    n._t.setAttribute("opacity", n.role === "leaf" ? "0.5" : n.role === "hub" ? "0.85" : "0.68");
    n._t.style.fontFamily = "'Geist', system-ui, sans-serif";
    if (n.role === "hub") n._t.style.fontWeight = "600";
  }
  function paintLink(k) {
    k._l.setAttribute("stroke", k.semantic ? C.semantic : C.edge);
    k._l.setAttribute("stroke-width", k.semantic ? "1.2" : "1");
    if (k.semantic) k._l.setAttribute("stroke-dasharray", "4 3");
    else k._l.removeAttribute("stroke-dasharray");
    k._l.setAttribute("opacity", k.kind === "cross" ? "0.35" : k.semantic ? "0.5" : "0.6");
  }
  function paintAll() { nodes.forEach(paintNode); links.forEach(paintLink); }
  if (window.matchMedia) {
    window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => { C = COLORS(); paintAll(); });
  }

  nodes.forEach(el); links.forEach(lel);

  // ---- force simulation ----
  const DIST = { member: 46, chain: 36, cross: 150 };
  const STR = { member: 0.6, chain: 0.65, cross: 0.06 };
  function tickPhysics() {
    for (const k of links) {
      const dx = k.t.x - k.s.x, dy = k.t.y - k.s.y;
      const d = Math.hypot(dx, dy) || 1;
      const rest = DIST[k.kind] || 46;
      const f = ((d - rest) / d) * (STR[k.kind] || 0.5) * 0.1;
      if (!k.s.fixed) { k.s.vx += dx * f; k.s.vy += dy * f; }
      if (!k.t.fixed) { k.t.vx -= dx * f; k.t.vy -= dy * f; }
    }
    for (let i = 0; i < nodes.length; i++) {
      const a = nodes[i];
      for (let j = i + 1; j < nodes.length; j++) {
        const b = nodes[j];
        let dx = b.x - a.x, dy = b.y - a.y;
        let d2 = dx * dx + dy * dy;
        if (d2 > 320 * 320) continue;
        if (d2 < 1) { dx = (Math.random() - 0.5); dy = (Math.random() - 0.5); d2 = 1; }
        const d = Math.sqrt(d2);
        const rep = (120 / d2) * 0.6;
        const rx = dx / d * rep, ry = dy / d * rep;
        if (!a.fixed) { a.vx -= rx * d; a.vy -= ry * d; }
        if (!b.fixed) { b.vx += rx * d; b.vy += ry * d; }
        if (d < 30) {
          const push = (30 - d) / d * 0.35;
          if (!a.fixed) { a.vx -= dx * push; a.vy -= dy * push; }
          if (!b.fixed) { b.vx += dx * push; b.vy += dy * push; }
        }
      }
    }
    const cx = W / 2, cy = H / 2;
    for (const n of nodes) {
      if (!n.fixed) {
        // home gravity: each node drifts toward its cluster's anchor…
        const cl = CLUSTERS.find((c) => c.key === n.cluster);
        if (cl) {
          const home = anchorOf(cl.angle, cl.depth);
          n.vx += (home.x - n.x) * 0.0045;
          n.vy += (home.y - n.y) * 0.0045;
        }
        // …but the hero's keep-out ellipse shoves everything out of the middle
        const dx = n.x - cx, dy = n.y - cy;
        const f = Math.sqrt((dx * dx) / (KX * KX) + (dy * dy) / (KY * KY)) || 0.001;
        if (f < 1.08) {
          const push = (1.08 - f) * 2.2;
          n.vx += (dx / f) * push / KX * 60;
          n.vy += (dy / f) * push / KY * 60;
        }
        n.vx += (Math.random() - 0.5) * 0.06;
        n.vy += (Math.random() - 0.5) * 0.06;
        n.vx *= 0.85; n.vy *= 0.85;
        n.x += n.vx; n.y += n.vy;
      }
      const m = 24;
      n.x = Math.max(m, Math.min(W - m, n.x));
      n.y = Math.max(m, Math.min(H - m, n.y));
    }
  }

  // ---- evolution: the fake data "moves, changes, evolves" ----
  function addNode() {
    if (nodes.length >= 72) return;
    const pick = EPHEMERAL[(Math.random() * EPHEMERAL.length) | 0];
    const anchor = nodes[(Math.random() * nodes.length) | 0];
    const n = mkNode(pick[0], pick[1], anchor.cluster, "leaf",
      anchor.x + (Math.random() - 0.5) * 60, anchor.y + (Math.random() - 0.5) * 60);
    n.ephemeral = true;
    nodes.push(n); el(n);
    const k = { s: anchor, t: n, semantic: Math.random() < 0.3, kind: "chain", flash: 1 };
    links.push(k); lel(k);
    anchor.pulse = 1;
    return n;
  }
  function removeNode() {
    const candidates = nodes.filter((n) => n.ephemeral && !n.dying);
    if (candidates.length < 4) return;
    candidates[(Math.random() * candidates.length) | 0].dying = performance.now();
  }
  function rewire() {
    const movable = links.filter((k) => k.kind === "chain" || k.kind === "member");
    const k = movable[(Math.random() * movable.length) | 0];
    if (!k) return;
    // rewire within the same cluster so clusters stay coherent
    const local = nodes.filter((n) => n.cluster === k.t.cluster && n !== k.t && n !== k.s && !n.dying);
    const n = local[(Math.random() * local.length) | 0];
    if (n) { k.s = n; k.flash = 1; }
  }
  function ripple(n) {
    n = n || nodes[(Math.random() * nodes.length) | 0];
    n.pulse = 1;
    for (const k of links) if (k.s === n || k.t === n) k.flash = 1;
    return n;
  }
  function evolve() {
    const r = Math.random();
    if (r < 0.3) addNode();
    else if (r < 0.5) removeNode();
    else if (r < 0.72) rewire();
    else ripple();
  }

  // Coach hook: the hero's phase cycler asks the graph to act out each phase
  // and gets back the focal node's position so the avatar can emit an
  // onboarding-style edge to it. sense → telemetry ripples; decide → the gate
  // rewires; act → a fresh node lands; learn → knowledge pulses.
  window.autopoetGraph = {
    trigger(phase) {
      let focal = null;
      if (phase === "sense") focal = ripple(byName("telemetry") || byName("drift"));
      else if (phase === "decide") { focal = byName("gate"); if (focal) { focal.pulse = 1; rewire(); } }
      else if (phase === "act") { focal = addNode() || byName("scratch"); if (focal) focal.pulse = 1; }
      else if (phase === "learn") focal = ripple(byName("knowledge") || byName("lesson"));
      return focal ? { node: focal } : null;
    },
    at(handle) { return handle && handle.node && nodes.includes(handle.node) ? { x: handle.node.x, y: handle.node.y } : null; },
  };

  // ---- pointer: hover highlights neighbourhood, drag pins (pure show) ----
  let hover = null, drag = null;
  svg.addEventListener("pointermove", (e) => {
    if (drag) { drag.x = e.clientX; drag.y = e.clientY; return; }
    hover = null;
    for (const n of nodes) {
      if (Math.hypot(n.x - e.clientX, n.y - e.clientY) < 16) { hover = n; break; }
    }
    svg.style.cursor = hover ? "grab" : "default";
  });
  svg.addEventListener("pointerdown", (e) => {
    if (hover) { drag = hover; drag.fixed = true; svg.setPointerCapture(e.pointerId); }
  });
  const drop = () => { if (drag) { drag.fixed = false; drag = null; } };
  svg.addEventListener("pointerup", drop);
  svg.addEventListener("pointercancel", drop);

  // ---- frame loop ----
  function neighbours(n) {
    const set = new Set([n]);
    for (const k of links) { if (k.s === n) set.add(k.t); if (k.t === n) set.add(k.s); }
    return set;
  }
  function render(now) {
    const lit = hover ? neighbours(hover) : null;
    for (let i = links.length - 1; i >= 0; i--) {
      const k = links[i];
      if (!nodes.includes(k.s) || !nodes.includes(k.t)) { k._l.remove(); links.splice(i, 1); continue; }
      if (k.kind === "cross") {
        // bow the control point outward so the curve clears the keep-out
        const cx = W / 2, cy = H / 2;
        const mx = (k.s.x + k.t.x) / 2, my = (k.s.y + k.t.y) / 2;
        const dx = mx - cx, dy = my - cy;
        const fm = Math.sqrt((dx * dx) / (KX * KX) + (dy * dy) / (KY * KY)) || 0.05;
        const boost = Math.max(2.1 / fm, 1.1);
        const qx = cx + dx * boost, qy = cy + dy * boost;
        k._l.setAttribute("d", `M ${k.s.x} ${k.s.y} Q ${qx} ${qy} ${k.t.x} ${k.t.y}`);
      } else {
        k._l.setAttribute("x1", k.s.x); k._l.setAttribute("y1", k.s.y);
        k._l.setAttribute("x2", k.t.x); k._l.setAttribute("y2", k.t.y);
      }
      if (k.flash > 0) {
        k.flash -= 0.02;
        k._l.setAttribute("stroke", C.ink);
        k._l.setAttribute("opacity", String(0.2 + 0.45 * k.flash));
        if (k.flash <= 0) paintLink(k);
      } else if (lit) {
        const on = lit.has(k.s) && lit.has(k.t);
        k._l.setAttribute("opacity", on ? "0.85" : "0.12");
      }
    }
    for (let i = nodes.length - 1; i >= 0; i--) {
      const n = nodes[i];
      const age = now - n.born;
      let scale = Math.min(1, age / 450);
      if (n.dying) {
        const gone = (now - n.dying) / 600;
        if (gone >= 1) { n._g.remove(); nodes.splice(i, 1); continue; }
        scale = 1 - gone;
      }
      let r = (n === hover ? baseR(n) + 2 : baseR(n)) * scale;
      if (n.pulse > 0) { r += 3.5 * Math.sin(n.pulse * Math.PI); n.pulse -= 0.02; }
      n._c.setAttribute("r", Math.max(0.5, r));
      n._c.setAttribute("stroke-width", n.pulse > 0.6 ? "2.5" : "1.5");
      n._g.setAttribute("transform", `translate(${n.x},${n.y})`);
      const dim = lit && !lit.has(n);
      n._g.setAttribute("opacity", dim ? 0.2 : Math.min(1, scale));
      const labelOn = W >= 640 && !(n.role === "leaf" && W < 1000);
      n._t.setAttribute("opacity", !labelOn ? "0" : dim ? "0.15"
        : n.role === "leaf" ? "0.5" : n.role === "hub" ? "0.85" : "0.68");
    }
  }

  addEventListener("resize", () => { W = innerWidth; H = innerHeight; sizeKeepOut(); });

  // settle the layout before first paint so it doesn't explode on load
  for (let i = 0; i < 220; i++) tickPhysics();

  if (reduced) {
    for (let i = 0; i < 300; i++) tickPhysics();
    render(performance.now());
    return;
  }

  let lastEvolve = performance.now();
  (function frame(now) {
    tickPhysics();
    render(now);
    if (now - lastEvolve > 1600 + Math.random() * 1400) { evolve(); lastEvolve = now; }
    requestAnimationFrame(frame);
  })(performance.now());
})();
