// data-on — the trigger grammar. ONE attribute that says WHEN a work-* element runs,
// modeled directly on HTMX's `hx-trigger` (locality of behavior: you read the element
// and know when it fires), spelled as a valid-HTML data-* attribute. Framework-agnostic
// — any element calls bindTriggers().
//
// grammar — comma-separated triggers, each `<event> [modifiers…]`:
//   <domevent>            click · input · submit · pointerenter · … (any DOM/custom event)
//   <work-event>          work-flow-done · work-run · … (our own events — this is how one
//                         flow chains off another: data-on="work-flow-done from:#ingest")
//   load                  fire once on connect           (was: autorun)
//   every <dur>           fire on an interval (polling)  (was: every=)
//   visible | reveal      fire when scrolled into view   (IntersectionObserver)
// modifiers:
//   once                  fire at most once
//   changed               only when the source element's value/text changed
//   delay:<dur>           debounce — reset on each event, fire after the quiet window
//   throttle:<dur>        rate-limit — at most once per window
//   from:<selector>       listen on other element(s) (document-scoped), not self
//   target:<selector>     carried into the fire detail (consumed by w-target later)
// durations: 250ms · 2s · 3m · 1h   (bare number ⇒ seconds)

const DUR = (s) => {
  const m = /^(\d+(?:\.\d+)?)(ms|s|m|h)?$/.exec(String(s || "").trim());
  return m ? (+m[1]) * ({ ms: 1, s: 1e3, m: 6e4, h: 36e5 }[m[2] || "s"]) : 0;
};

export function parseTriggers(spec) {
  return String(spec || "").split(",").map((s) => s.trim()).filter(Boolean).map((part) => {
    const toks = part.split(/\s+/);
    const event = toks.shift();
    const t = { event, once: false, changed: false, delay: 0, throttle: 0, from: null, target: null, every: 0 };
    if (event === "every") t.every = DUR(toks.shift()) || 1000;
    for (const tok of toks) {
      if (tok === "once") t.once = true;
      else if (tok === "changed") t.changed = true;
      else if (tok.startsWith("delay:")) t.delay = DUR(tok.slice(6));
      else if (tok.startsWith("throttle:")) t.throttle = DUR(tok.slice(9));
      else if (tok.startsWith("from:")) t.from = tok.slice(5);
      else if (tok.startsWith("target:")) t.target = tok.slice(7);
    }
    return t;
  });
}

/**
 * Wire a trigger spec to a fire callback. Returns an unbind() — call it in disconnectedCallback.
 * @param {Element} el    the host element (self-scope + the visible/intersection node)
 * @param {string}  spec  the data-on string
 * @param {(detail:object)=>void} fire  invoked when a trigger fires; detail carries {event, target?}
 */
export function bindTriggers(el, spec, fire) {
  const cleanups = [];
  for (const t of parseTriggers(spec)) {
    let fired = 0, lastVal, throttledUntil = 0, timer;
    const go = (detail) => { if (t.once && fired) return; fired++; fire({ ...detail, trigger: t }); };
    const guarded = (e) => {
      const src = e && e.target;
      if (t.changed) {
        const v = src ? ("value" in src ? src.value : src.textContent) : undefined;
        if (v === lastVal) return; lastVal = v;
      }
      if (t.throttle) { const now = performance.now(); if (now < throttledUntil) return; throttledUntil = now + t.throttle; }
      if (t.delay) { clearTimeout(timer); timer = setTimeout(() => go({ event: e && e.type, target: src }), t.delay); return; }
      go({ event: e && e.type, target: src });
    };

    if (t.event === "load") {
      queueMicrotask(() => go({ event: "load" }));
    } else if (t.event === "every") {
      const id = setInterval(() => go({ event: "every" }), t.every);
      cleanups.push(() => clearInterval(id));
    } else if (t.event === "visible" || t.event === "reveal") {
      const io = new IntersectionObserver((ents) => {
        for (const en of ents) if (en.isIntersecting) { guarded({ type: t.event }); if (t.once) io.disconnect(); }
      });
      io.observe(el);
      cleanups.push(() => io.disconnect());
    } else {
      // a DOM or custom event — on self, or on from: targets (e.g. another flow's work-flow-done)
      const targets = t.from ? Array.from(document.querySelectorAll(t.from)) : [el];
      for (const tg of targets) { tg.addEventListener(t.event, guarded); cleanups.push(() => tg.removeEventListener(t.event, guarded)); }
    }
  }
  return () => { for (const fn of cleanups) fn(); };
}
