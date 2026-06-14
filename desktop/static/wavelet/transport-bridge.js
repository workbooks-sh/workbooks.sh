// Wavelet transport bridge — injected into a composition iframe by the
// desktop WaveletPlayer. The iframe is sandboxed (allow-scripts, NO
// allow-same-origin), so the parent cannot touch the iframe document
// directly; all transport flows over postMessage.
//
// PREVIEW == RENDER is the contract. The render core (render_seq.wasm,
// Blitz+Stylo) produces frame N by seeking the CSS-animation clock to
// t = N / fps and repainting. The browser twin of that seek is the Web
// Animations API: pause every running animation and set its currentTime
// to the same t (in ms). So scrubbing to frame N here paints the same
// visual state the renderer writes to frame_%05dN.png.
//
// Messages IN (from parent):
//   { type: "wavelet:seek",  timeMs }   — seek the clock, stay paused
//   { type: "wavelet:play",  fromMs }   — resume real-time playback
//   { type: "wavelet:pause" }           — freeze the clock
// Messages OUT (to parent):
//   { type: "wavelet:ready", fps, durationMs, width, height }
//   { type: "wavelet:tick",  timeMs }   — during play, ~each frame
(function () {
  "use strict";

  var fps = 30;
  var durationMs = 2000;
  var width = 1280;
  var height = 720;

  // --- read composition metadata (matches render-core arg defaults) ---
  function readMeta(name) {
    var el = document.querySelector('meta[name="' + name + '"]');
    return el ? el.getAttribute("content") : null;
  }
  function parseDurationMs(v) {
    if (!v) return null;
    var s = String(v).trim();
    var m = s.match(/^([\d.]+)\s*(ms|s)?$/);
    if (!m) return null;
    var n = parseFloat(m[1]);
    if (!isFinite(n)) return null;
    return m[2] === "ms" ? n : n * 1000; // bare/"s" -> seconds
  }

  function applyMeta() {
    var f = parseFloat(readMeta("fps"));
    if (isFinite(f) && f > 0) fps = f;
    var d = parseDurationMs(readMeta("duration"));
    if (d != null && d > 0) durationMs = d;
    var res = readMeta("resolution");
    if (res) {
      var rm = res.match(/^(\d+)\s*[x×]\s*(\d+)$/i);
      if (rm) { width = parseInt(rm[1], 10); height = parseInt(rm[2], 10); }
    }
  }

  // --- the deterministic clock (the render twin) ---
  // We never let CSS animations free-run; we own the clock. Every active
  // animation is paused and its currentTime is pinned, exactly like the
  // renderer pinning Stylo's animation clock per frame.
  var clockMs = 0;
  var playing = false;
  var rafId = null;
  var anchorWall = 0;
  var anchorMs = 0;

  function allAnimations() {
    try {
      // getAnimations() on the document captures CSS @keyframes-driven
      // animations across the whole tree (the render-core vocabulary).
      return document.getAnimations ? document.getAnimations() : [];
    } catch (e) {
      return [];
    }
  }

  function pinClock(t) {
    clockMs = t;
    var anims = allAnimations();
    for (var i = 0; i < anims.length; i++) {
      var a = anims[i];
      try {
        a.pause();
        a.currentTime = t;
      } catch (e) { /* some animations are read-only mid-resolve */ }
    }
    // gm-* runtime, if present, exposes a doc whose playhead we seek too,
    // so gm-driven motion tracks the same clock.
    var gm = document.querySelector("gm-doc");
    if (gm && typeof gm.seekFrame === "function") {
      try {
        gm.pause();
        gm.seekFrame(Math.round((t / 1000) * (gm.fps || fps)));
      } catch (e) {}
    }
  }

  function loop(now) {
    if (!playing) return;
    var t = anchorMs + (now - anchorWall);
    if (t >= durationMs) {
      pinClock(durationMs);
      playing = false;
      post("wavelet:tick", { timeMs: durationMs });
      post("wavelet:ended", {});
      return;
    }
    pinClock(t);
    post("wavelet:tick", { timeMs: t });
    rafId = requestAnimationFrame(loop);
  }

  function play(fromMs) {
    if (typeof fromMs === "number") clockMs = fromMs;
    if (clockMs >= durationMs) clockMs = 0;
    playing = true;
    anchorWall = performance.now();
    anchorMs = clockMs;
    var gm = document.querySelector("gm-doc");
    if (gm && typeof gm.play === "function") { try { gm.play(); } catch (e) {} }
    rafId = requestAnimationFrame(loop);
  }

  function pause() {
    playing = false;
    if (rafId != null) { cancelAnimationFrame(rafId); rafId = null; }
    pinClock(clockMs);
  }

  function post(type, extra) {
    var msg = { type: type };
    if (extra) for (var k in extra) msg[k] = extra[k];
    try { parent.postMessage(msg, "*"); } catch (e) {}
  }

  window.addEventListener("message", function (e) {
    var d = e.data;
    if (!d || typeof d !== "object") return;
    switch (d.type) {
      case "wavelet:seek":
        pause();
        pinClock(Math.max(0, Math.min(durationMs, +d.timeMs || 0)));
        break;
      case "wavelet:play":
        play(typeof d.fromMs === "number" ? d.fromMs : undefined);
        break;
      case "wavelet:pause":
        pause();
        break;
    }
  });

  function start() {
    applyMeta();
    // Pin to t=0 (paused) so first paint equals frame 0 of the render.
    pinClock(0);
    post("wavelet:ready", {
      fps: fps, durationMs: durationMs, width: width, height: height,
    });
  }

  if (document.readyState === "complete" || document.readyState === "interactive") {
    // Give the gm-* runtime (if injected before us) a tick to register
    // and build its viewport, then take the clock.
    setTimeout(start, 0);
  } else {
    window.addEventListener("DOMContentLoaded", function () { setTimeout(start, 0); });
  }
})();
