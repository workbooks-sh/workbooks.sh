// runtime/wavelet/runtime/src/types.ts
class GamutError extends Error {
  cause;
  constructor(message, cause) {
    super(message);
    this.cause = cause;
    this.name = "GamutError";
  }
}

// runtime/wavelet/runtime/src/parser.ts
function parseFromElement(root, opts = {}) {
  if (root.tagName.toLowerCase() !== "gm-doc") {
    throw new GamutError(`expected <gm-doc> root, got <${root.tagName.toLowerCase()}>`);
  }
  const fps = parseInt10(attrRequired(root, "fps"), "<gm-doc fps>");
  const resolution = parseResolution(attrRequired(root, "resolution"));
  const assetEls = queryDirectChildren(root, "gm-asset");
  const compositionEls = queryDirectChildren(root, "gm-composition");
  const timelineEl = queryDirectChildren(root, "gm-timeline")[0];
  if (!timelineEl) {
    throw new GamutError("<gm-doc> must contain a <gm-timeline> child");
  }
  return {
    version: attrOr(root, "version", "1"),
    fps,
    resolution,
    aspect: attrRequired(root, "aspect"),
    assets: assetEls.map(parseAsset),
    compositions: compositionEls.map(parseComposition),
    timeline: parseTimeline(timelineEl, opts)
  };
}
function parseAsset(el) {
  return {
    id: attrRequired(el, "id"),
    kind: attrRequired(el, "kind"),
    src: attrRequired(el, "src")
  };
}
function parseComposition(el) {
  return {
    id: attrRequired(el, "id"),
    src: attrRequired(el, "src")
  };
}
function parseTimeline(el, opts) {
  const tracks = queryDirectChildren(el, "gm-track").map((t) => parseTrack(t, opts));
  return {
    id: attrRequired(el, "id"),
    duration: attrRequired(el, "duration"),
    tracks
  };
}
function parseTrack(el, opts) {
  const z = parseInt10(attrRequired(el, "z"), "<gm-track z>");
  const items = [];
  for (const child of elementChildren(el)) {
    const item = parseTrackItem(child, opts);
    if (item)
      items.push(item);
  }
  return {
    id: attrRequired(el, "id"),
    z,
    items,
    ...visualAttrs(el)
  };
}
function parseTrackItem(el, opts) {
  const tag = el.tagName.toLowerCase();
  switch (tag) {
    case "gm-clip":
      return parseClip(el);
    case "gm-scene":
      return parseScene(el);
    case "gm-audio":
      return parseAudio(el);
    case "gm-shader":
      return parseShader(el);
    case "gm-adjustment":
      return parseAdjustment(el);
    case "gm-include":
      return parseInclude(el);
    default:
      if (opts.strict) {
        throw new GamutError(`unknown track item <${tag}> (strict mode). Allowed: gm-clip, gm-scene, gm-audio, gm-shader, gm-adjustment, gm-include.`);
      }
      return null;
  }
}
function parseClip(el) {
  return {
    kind: "clip",
    id: attrOpt(el, "id"),
    asset: attrRequired(el, "asset"),
    start: attrRequired(el, "start"),
    duration: attrOpt(el, "duration"),
    in: attrOpt(el, "in"),
    out: attrOpt(el, "out"),
    ...visualAttrs(el)
  };
}
function parseScene(el) {
  const src = attrOpt(el, "src");
  const tmpl = elementChildren(el).find((c) => c.tagName.toLowerCase() === "template");
  const inline = src ? undefined : tmpl ? tmpl.innerHTML.trim() || undefined : el.innerHTML.trim() || undefined;
  return {
    kind: "scene",
    id: attrOr(el, "id", `scene-${anonSceneCounter()}`),
    start: attrRequired(el, "start"),
    duration: attrRequired(el, "duration"),
    src,
    inlineHtml: inline,
    ...visualAttrs(el)
  };
}
function parseAudio(el) {
  return {
    kind: "audio",
    id: attrOpt(el, "id"),
    asset: attrRequired(el, "asset"),
    start: attrRequired(el, "start"),
    duration: attrRequired(el, "duration"),
    volume: parseFloatAttr(el, "volume"),
    pan: parseFloatAttr(el, "pan"),
    duck: parseFloatAttr(el, "duck"),
    fadeIn: parseFloatAttr(el, "fade-in") ?? parseFloatAttr(el, "fadeIn"),
    fadeOut: parseFloatAttr(el, "fade-out") ?? parseFloatAttr(el, "fadeOut"),
    loop: parseBoolAttr(el, "loop"),
    ...visualAttrs(el)
  };
}
function parseShader(el) {
  const src = attrOpt(el, "src");
  return {
    kind: "shader",
    id: attrOpt(el, "id"),
    lang: attrRequired(el, "lang"),
    start: attrRequired(el, "start"),
    duration: attrRequired(el, "duration"),
    src,
    inlineSource: src ? undefined : el.textContent?.trim() || undefined,
    ...visualAttrs(el)
  };
}
function parseAdjustment(el) {
  return {
    kind: "adjustment",
    id: attrOpt(el, "id"),
    filter: attrRequired(el, "filter"),
    start: attrRequired(el, "start"),
    duration: attrRequired(el, "duration"),
    backdrop: attrOpt(el, "backdrop"),
    blend: attrOpt(el, "blend"),
    ...visualAttrs(el)
  };
}
function parseInclude(el) {
  const ref = attrOpt(el, "ref");
  const src = attrOpt(el, "src");
  if (!ref && !src) {
    throw new GamutError("<gm-include> must have either ref= or src=");
  }
  if (ref && src) {
    throw new GamutError("<gm-include> cannot have both ref= and src= — pick one (ref= points at a <gm-composition>, src= loads an external file)");
  }
  return {
    kind: "include",
    id: attrOpt(el, "id"),
    start: attrRequired(el, "start"),
    duration: attrRequired(el, "duration"),
    ref,
    src,
    ...visualAttrs(el)
  };
}
function attrRequired(el, name) {
  const v = el.getAttribute(name);
  if (v === null || v.trim().length === 0) {
    throw new GamutError(`<${el.tagName.toLowerCase()}> requires attribute '${name}'`);
  }
  return v.trim();
}
function attrOr(el, name, fallback) {
  const v = el.getAttribute(name);
  return v === null || v.trim().length === 0 ? fallback : v.trim();
}
function attrOpt(el, name) {
  const v = el.getAttribute(name);
  return v === null || v.trim().length === 0 ? undefined : v.trim();
}
function visualAttrs(el) {
  return {
    class: attrOpt(el, "class"),
    style: attrOpt(el, "style")
  };
}
function parseFloatAttr(el, name) {
  const v = el.getAttribute(name);
  if (v === null)
    return;
  const n = Number(v.trim());
  return Number.isFinite(n) ? n : undefined;
}
function parseBoolAttr(el, name) {
  const v = el.getAttribute(name);
  if (v === null)
    return;
  const t = v.trim().toLowerCase();
  if (t === "" || t === "true" || t === "1" || t === name)
    return true;
  if (t === "false" || t === "0")
    return false;
  return;
}
function parseInt10(value, label) {
  if (!/^-?\d+$/.test(value)) {
    throw new GamutError(`${label} must be an integer, got '${value}'`);
  }
  return Number(value);
}
function parseResolution(value) {
  const m = value.match(/^(\d+)x(\d+)$/);
  if (!m) {
    throw new GamutError(`<gm-doc resolution='${value}'> must look like '1920x1080'`);
  }
  return { width: Number(m[1]), height: Number(m[2]) };
}
function elementChildren(el) {
  const out = [];
  for (const child of Array.from(el.childNodes)) {
    if (isElement(child))
      out.push(child);
  }
  return out;
}
function queryDirectChildren(parent, tagName) {
  return elementChildren(parent).filter((c) => c.tagName.toLowerCase() === tagName);
}
function isElement(node) {
  return node.nodeType === 1;
}
var __anonScene = 0;
function anonSceneCounter() {
  return ++__anonScene;
}

// runtime/wavelet/runtime/src/time.ts
function parseTime(raw, fps) {
  const value = raw.trim();
  if (value.length === 0) {
    throw new GamutError(`invalid time '${raw}': time value is empty`);
  }
  if (fps <= 0 || !Number.isFinite(fps)) {
    throw new GamutError(`invalid time '${raw}': fps must be greater than zero`);
  }
  if (value.endsWith("f")) {
    const body = value.slice(0, -1);
    if (!/^\d+$/.test(body)) {
      throw new GamutError(`invalid time '${raw}': frame values must be unsigned integers like 12f`);
    }
    return { frames: Number(body) };
  }
  if (value.endsWith("s")) {
    return parseSeconds(value, value.slice(0, -1), fps);
  }
  if ((value.match(/:/g) ?? []).length === 3) {
    return parseTimecode(value, fps);
  }
  throw new GamutError(`invalid time '${raw}': expected frames (12f), seconds (4s), or timecode (00:00:04:12)`);
}
function parseSeconds(original, body, fps) {
  const dot = body.indexOf(".");
  const whole = dot === -1 ? body : body.slice(0, dot);
  const frac = dot === -1 ? "" : body.slice(dot + 1);
  if (whole.length === 0 || !/^\d+$/.test(whole)) {
    throw new GamutError(`invalid time '${original}': seconds must be a non-negative decimal number`);
  }
  if (frac.length > 0 && !/^\d+$/.test(frac)) {
    throw new GamutError(`invalid time '${original}': seconds must be a non-negative decimal number`);
  }
  const fpsB = BigInt(fps);
  const wholeFrames = BigInt(whole) * fpsB;
  let fracFrames = 0n;
  if (frac.length > 0) {
    const numerator = BigInt(frac);
    const denominator = 10n ** BigInt(frac.length);
    const scaled = numerator * fpsB;
    if (scaled % denominator !== 0n) {
      throw new GamutError(`invalid time '${original}': seconds must resolve exactly to whole frames at this fps`);
    }
    fracFrames = scaled / denominator;
  }
  const total = wholeFrames + fracFrames;
  if (total > 0xffff_ffffn) {
    throw new GamutError(`invalid time '${original}': time value overflows frame range`);
  }
  return { frames: Number(total) };
}
function parseTimecode(value, fps) {
  const parts = value.split(":");
  if (parts.length !== 4) {
    throw new GamutError(`invalid time '${value}': timecode must have four fields`);
  }
  const [hh, mm, ss, ff] = parts;
  const hours = parseTcPart(value, hh, "hours");
  const minutes = parseTcPart(value, mm, "minutes");
  const seconds = parseTcPart(value, ss, "seconds");
  const frames = parseTcPart(value, ff, "frames");
  if (minutes >= 60 || seconds >= 60) {
    throw new GamutError(`invalid time '${value}': timecode minutes and seconds must be less than 60`);
  }
  if (frames >= fps) {
    throw new GamutError(`invalid time '${value}': timecode frame component must be less than fps`);
  }
  const totalSeconds = BigInt(hours) * 3600n + BigInt(minutes) * 60n + BigInt(seconds);
  const total = totalSeconds * BigInt(fps) + BigInt(frames);
  if (total > 0xffff_ffffn) {
    throw new GamutError(`invalid time '${value}': timecode overflows frame range`);
  }
  return { frames: Number(total) };
}
function parseTcPart(value, part, label) {
  if (part.length !== 2 || !/^\d{2}$/.test(part)) {
    throw new GamutError(`invalid time '${value}': timecode ${label} must be two digits`);
  }
  return Number(part);
}

// runtime/wavelet/runtime/src/timeline.ts
function resolveTimeline(doc) {
  const fps = doc.fps;
  if (!Number.isInteger(fps) || fps <= 0) {
    throw new GamutError(`fps must be a positive integer; got ${doc.fps}`);
  }
  const durationFrames = parseTime(doc.timeline.duration, fps).frames;
  const tracks = doc.timeline.tracks.map((t) => resolveTrack(t, fps));
  return {
    version: doc.version,
    fps,
    resolution: doc.resolution,
    aspect: doc.aspect,
    durationFrames,
    assets: doc.assets,
    compositions: doc.compositions,
    tracks
  };
}
function resolveTrack(track, fps) {
  const items = track.items.map((it) => resolveItem(it, fps, track.id));
  return {
    id: track.id,
    z: track.z,
    class: track.class,
    style: track.style,
    items
  };
}
function resolveItem(item, fps, trackId) {
  const startFrame = parseTime(item.start, fps).frames;
  switch (item.kind) {
    case "clip":
      return resolveClip(item, fps, startFrame, trackId);
    case "scene":
      return resolveScene(item, fps, startFrame);
    case "audio":
      return resolveAudio(item, fps, startFrame);
    case "shader":
      return resolveShader(item, fps, startFrame);
    case "adjustment":
      return resolveAdjustment(item, fps, startFrame);
    case "include":
      return resolveInclude(item, fps, startFrame);
  }
}
function resolveClip(clip, fps, startFrame, trackId) {
  const sourceIn = clip.in ? parseTime(clip.in, fps).frames : undefined;
  const sourceOut = clip.out ? parseTime(clip.out, fps).frames : undefined;
  let endFrame;
  let sourceInFrame;
  let sourceOutFrame;
  if (clip.duration) {
    const durFrames = parseTime(clip.duration, fps).frames;
    endFrame = startFrame + durFrames;
    sourceInFrame = sourceIn ?? 0;
    sourceOutFrame = sourceOut ?? sourceInFrame + durFrames;
  } else if (sourceIn !== undefined && sourceOut !== undefined) {
    const durFrames = sourceOut - sourceIn;
    if (durFrames <= 0) {
      throw new GamutError(`<gm-clip asset="${clip.asset}"> on track '${trackId}': out (${clip.out}) must be after in (${clip.in})`);
    }
    endFrame = startFrame + durFrames;
    sourceInFrame = sourceIn;
    sourceOutFrame = sourceOut;
  } else {
    throw new GamutError(`<gm-clip asset="${clip.asset}"> on track '${trackId}' requires either duration= or BOTH in= and out=`);
  }
  return {
    kind: "clip",
    asset: clip.asset,
    startFrame,
    endFrame,
    sourceInFrame,
    sourceOutFrame,
    class: clip.class,
    style: clip.style
  };
}
function resolveScene(scene, fps, startFrame) {
  const endFrame = startFrame + parseTime(scene.duration, fps).frames;
  return {
    kind: "scene",
    id: scene.id,
    startFrame,
    endFrame,
    src: scene.src,
    inlineHtml: scene.inlineHtml,
    class: scene.class,
    style: scene.style
  };
}
function resolveAudio(cue, fps, startFrame) {
  return {
    kind: "audio",
    asset: cue.asset,
    startFrame,
    endFrame: startFrame + parseTime(cue.duration, fps).frames,
    volume: cue.volume,
    pan: cue.pan,
    duck: cue.duck,
    fadeIn: cue.fadeIn,
    fadeOut: cue.fadeOut,
    loop: cue.loop,
    class: cue.class,
    style: cue.style
  };
}
function resolveShader(shader, fps, startFrame) {
  return {
    kind: "shader",
    lang: shader.lang,
    startFrame,
    endFrame: startFrame + parseTime(shader.duration, fps).frames,
    src: shader.src,
    inlineSource: shader.inlineSource,
    class: shader.class,
    style: shader.style
  };
}
function resolveAdjustment(adj, fps, startFrame) {
  return {
    kind: "adjustment",
    filter: adj.filter,
    startFrame,
    endFrame: startFrame + parseTime(adj.duration, fps).frames,
    backdrop: adj.backdrop,
    blend: adj.blend,
    class: adj.class,
    style: adj.style
  };
}
function resolveInclude(inc, fps, startFrame) {
  return {
    kind: "include",
    startFrame,
    endFrame: startFrame + parseTime(inc.duration, fps).frames,
    ref: inc.ref,
    src: inc.src,
    class: inc.class,
    style: inc.style
  };
}

// runtime/wavelet/runtime/src/playhead.ts
function createPlayhead(opts) {
  let fps = opts.fps;
  let playing = false;
  let frame = 0;
  let anchorWallMs = 0;
  let anchorFrame = 0;
  let rafId = null;
  function loop(now) {
    if (!playing)
      return;
    const elapsedSec = (now - anchorWallMs) / 1000;
    const next = Math.floor(anchorFrame + elapsedSec * fps);
    const total = opts.getDurationFrames();
    if (total > 0 && next >= total) {
      frame = total - 1;
      opts.onTick(frame);
      playing = false;
      opts.onEnd?.();
      return;
    }
    if (next !== frame) {
      frame = next;
      opts.onTick(frame);
    }
    rafId = requestAnimationFrame(loop);
  }
  return {
    play() {
      if (playing)
        return;
      const total = opts.getDurationFrames();
      if (total > 0 && frame >= total - 1) {
        frame = 0;
        opts.onTick(frame);
      }
      playing = true;
      anchorWallMs = performance.now();
      anchorFrame = frame;
      rafId = requestAnimationFrame(loop);
    },
    pause() {
      if (!playing)
        return;
      playing = false;
      if (rafId !== null) {
        cancelAnimationFrame(rafId);
        rafId = null;
      }
    },
    toggle() {
      if (playing)
        this.pause();
      else
        this.play();
    },
    seek(target) {
      const total = opts.getDurationFrames();
      const clamped = total > 0 ? Math.max(0, Math.min(total - 1, target)) : Math.max(0, target);
      frame = clamped;
      anchorWallMs = performance.now();
      anchorFrame = clamped;
      opts.onTick(frame);
    },
    seekSeconds(seconds) {
      this.seek(Math.round(seconds * fps));
    },
    setFps(next) {
      if (next <= 0 || !Number.isFinite(next))
        return;
      anchorFrame = frame;
      anchorWallMs = performance.now();
      fps = next;
    },
    destroy() {
      playing = false;
      if (rafId !== null) {
        cancelAnimationFrame(rafId);
        rafId = null;
      }
    },
    get playing() {
      return playing;
    },
    get frame() {
      return frame;
    },
    get fps() {
      return fps;
    }
  };
}

// runtime/wavelet/runtime/src/audioMixer.ts
class AudioMixer {
  ctx = null;
  master = null;
  cues = [];
  fps = 30;
  baseUrl = null;
  destroyed = false;
  playing = false;
  bufferCache = new Map;
  constructor(opts) {
    this.fps = Math.max(1, opts.fps);
    this.baseUrl = opts.baseUrl ?? null;
  }
  async load(cues, assets) {
    this.ensureContext();
    if (!this.ctx || !this.master)
      return;
    const assetById = new Map(assets.map((a) => [a.id, a]));
    const keyOf = (c) => `${c.asset}@${c.startFrame}-${c.endFrame}`;
    const nextKeys = new Set(cues.map(keyOf));
    this.cues = this.cues.filter((r) => {
      if (nextKeys.has(keyOf(r.cue)))
        return true;
      this.stopCue(r);
      return false;
    });
    const existing = new Set(this.cues.map((r) => keyOf(r.cue)));
    for (const cue of cues) {
      if (existing.has(keyOf(cue)))
        continue;
      const asset = assetById.get(cue.asset);
      if (!asset)
        continue;
      const gain = this.ctx.createGain();
      const panner = this.ctx.createStereoPanner();
      gain.gain.value = 0;
      panner.pan.value = cue.pan ?? 0;
      gain.connect(panner).connect(this.master);
      const runtime = {
        cue,
        asset,
        source: null,
        gain,
        panner,
        buffer: null,
        lastApplied: -1,
        active: false
      };
      this.cues.push(runtime);
      this.loadBuffer(asset).then((buf) => {
        if (this.destroyed)
          return;
        runtime.buffer = buf;
      });
    }
  }
  seek(frame) {
    if (!this.ctx)
      return;
    const seconds = frame / this.fps;
    let activeDuckDb = 0;
    for (const r of this.cues) {
      const within = frame >= r.cue.startFrame && frame < r.cue.endFrame;
      if (within && (r.cue.duck ?? 0) > activeDuckDb) {
        activeDuckDb = r.cue.duck ?? 0;
      }
    }
    const duckLinear = activeDuckDb > 0 ? Math.pow(10, -activeDuckDb / 20) : 1;
    for (const r of this.cues) {
      const within = frame >= r.cue.startFrame && frame < r.cue.endFrame;
      if (!within) {
        if (r.active)
          this.stopCue(r);
        continue;
      }
      const cueSeconds = seconds - r.cue.startFrame / this.fps;
      const cueLen = (r.cue.endFrame - r.cue.startFrame) / this.fps;
      const baseVol = r.cue.volume ?? 1;
      const fadeIn = r.cue.fadeIn ?? 0;
      const fadeOut = r.cue.fadeOut ?? 0;
      let envelope = 1;
      if (fadeIn > 0 && cueSeconds < fadeIn)
        envelope *= cueSeconds / fadeIn;
      if (fadeOut > 0 && cueSeconds > cueLen - fadeOut) {
        envelope *= Math.max(0, (cueLen - cueSeconds) / fadeOut);
      }
      const isDuckSource = (r.cue.duck ?? 0) >= activeDuckDb && activeDuckDb > 0;
      const duckMul = isDuckSource ? 1 : duckLinear;
      r.gain.gain.value = baseVol * envelope * duckMul;
      if (this.playing && !r.active && r.buffer) {
        this.startCueAt(r, cueSeconds);
      } else if (r.active && r.source) {
        if (Math.abs(cueSeconds - r.lastApplied) > 0.1 && !this.playing) {
          this.stopCue(r);
        } else {
          r.lastApplied = cueSeconds;
        }
      }
    }
  }
  play() {
    this.ensureContext();
    if (!this.ctx)
      return;
    if (this.ctx.state === "suspended")
      this.ctx.resume();
    this.playing = true;
  }
  pause() {
    this.playing = false;
    for (const r of this.cues) {
      if (r.active)
        this.stopCue(r);
    }
  }
  destroy() {
    this.destroyed = true;
    this.pause();
    if (this.ctx && this.ctx.state !== "closed") {
      this.ctx.close().catch(() => {
        return;
      });
    }
    this.cues = [];
    this.ctx = null;
    this.master = null;
  }
  setMasterVolume(value, muted) {
    if (!this.master)
      return;
    this.master.gain.value = muted ? 0 : Math.max(0, Math.min(1, value));
  }
  ensureContext() {
    if (this.ctx || typeof window === "undefined")
      return;
    const Ctor = window.AudioContext ?? window.webkitAudioContext;
    if (!Ctor)
      return;
    this.ctx = new Ctor;
    this.master = this.ctx.createGain();
    this.master.gain.value = 1;
    this.master.connect(this.ctx.destination);
  }
  async loadBuffer(asset) {
    const url = this.resolveUrl(asset.src);
    const existing = this.bufferCache.get(url);
    if (existing)
      return existing;
    const p = (async () => {
      const res = await fetch(url);
      if (!res.ok)
        throw new Error(`audio fetch ${url} → ${res.status}`);
      const arr = await res.arrayBuffer();
      return await new Promise((resolve, reject) => {
        this.ctx.decodeAudioData(arr, resolve, reject);
      });
    })();
    this.bufferCache.set(url, p);
    return p;
  }
  resolveUrl(src) {
    if (!this.baseUrl)
      return src;
    try {
      return new URL(src, new URL(this.baseUrl, window.location.href)).toString();
    } catch {
      return src;
    }
  }
  startCueAt(r, offsetSeconds) {
    if (!this.ctx || !r.buffer)
      return;
    const node = this.ctx.createBufferSource();
    node.buffer = r.buffer;
    node.connect(r.gain);
    const safeOffset = Math.max(0, offsetSeconds % r.buffer.duration);
    try {
      node.start(0, safeOffset);
    } catch {}
    r.source = node;
    r.lastApplied = offsetSeconds;
    r.active = true;
  }
  stopCue(r) {
    if (r.source) {
      try {
        r.source.stop();
      } catch {}
      try {
        r.source.disconnect();
      } catch {}
    }
    r.source = null;
    r.active = false;
    r.lastApplied = -1;
  }
}

// runtime/wavelet/runtime/src/events.ts
function onReady(callbackOrSceneId, maybeCallback) {
  const sceneId = typeof callbackOrSceneId === "string" ? callbackOrSceneId : null;
  const cb = typeof callbackOrSceneId === "string" ? maybeCallback : callbackOrSceneId;
  if (!cb)
    throw new Error("onReady requires a callback");
  const handler = (e) => {
    const ce = e;
    if (sceneId && ce.detail.sceneId !== sceneId)
      return;
    cb(ce.detail, e.target);
  };
  document.addEventListener("hf:ready", handler);
  return () => document.removeEventListener("hf:ready", handler);
}
function onTick(callbackOrSceneId, maybeCallback) {
  const sceneId = typeof callbackOrSceneId === "string" ? callbackOrSceneId : null;
  const cb = typeof callbackOrSceneId === "string" ? maybeCallback : callbackOrSceneId;
  if (!cb)
    throw new Error("onTick requires a callback");
  const handler = (e) => {
    const ce = e;
    if (sceneId && ce.detail.sceneId !== sceneId)
      return;
    cb(ce.detail, e.target);
  };
  document.addEventListener("hf:tick", handler);
  return () => document.removeEventListener("hf:tick", handler);
}
var TIMELINE_REGISTRY = new Map;
function registerTimeline(sceneId, tl) {
  if (!sceneId || !tl)
    throw new Error("registerTimeline requires (sceneId, timeline)");
  TIMELINE_REGISTRY.set(sceneId, tl);
  if (typeof window !== "undefined") {
    const w = window;
    w.__timelines = w.__timelines ?? {};
    w.__timelines[sceneId] = tl;
  }
}
function getRegisteredTimeline(sceneId) {
  const direct = TIMELINE_REGISTRY.get(sceneId);
  if (direct)
    return direct;
  if (typeof window !== "undefined") {
    const w = window;
    const fromWindow = w.__timelines?.[sceneId];
    if (fromWindow && typeof fromWindow.progress === "function") {
      return fromWindow;
    }
  }
  return null;
}
function clearRegisteredTimeline(sceneId) {
  TIMELINE_REGISTRY.delete(sceneId);
  if (typeof window !== "undefined") {
    const w = window;
    if (w.__timelines)
      delete w.__timelines[sceneId];
  }
}
function dispatchReady(target, detail) {
  target.dispatchEvent(new CustomEvent("hf:ready", { bubbles: true, detail }));
}
function dispatchTick(target, detail) {
  const tl = getRegisteredTimeline(detail.sceneId);
  if (tl) {
    const total = Math.max(1, detail.durationFrames);
    const p = Math.max(0, Math.min(1, detail.frame / total));
    try {
      tl.progress(p);
    } catch {}
  }
  target.dispatchEvent(new CustomEvent("hf:tick", { bubbles: true, detail }));
}

// runtime/wavelet/runtime/src/sceneMount.ts
async function mountScene(scene, ctx) {
  const el = document.createElement("div");
  el.className = "gm-scene-mount";
  el.dataset.sceneId = scene.id;
  el.style.position = "absolute";
  el.style.inset = "0";
  el.style.zIndex = String(ctx.zIndex);
  if (scene.class)
    el.classList.add(...scene.class.split(/\s+/).filter(Boolean));
  if (scene.style)
    el.setAttribute("style", el.getAttribute("style") + ";" + scene.style);
  ctx.viewport.appendChild(el);
  if (scene.inlineHtml) {
    el.innerHTML = scene.inlineHtml;
    executeScripts(el, `scene:${scene.id}`);
  } else if (scene.src) {
    try {
      const url = resolveUrl(scene.src, ctx.baseUrl);
      const res = await fetch(url);
      if (res.ok) {
        const html = await res.text();
        el.innerHTML = html;
        executeScripts(el);
      } else {
        el.textContent = `[scene fetch failed: ${url} → ${res.status}]`;
      }
    } catch (e) {
      el.textContent = `[scene fetch error: ${e instanceof Error ? e.message : String(e)}]`;
    }
  }
  const startMs = scene.startFrame / ctx.fps * 1000;
  const durationFrames = scene.endFrame - scene.startFrame;
  const durationMs = durationFrames / ctx.fps * 1000;
  await Promise.resolve();
  dispatchReady(el, {
    sceneId: scene.id,
    fps: ctx.fps,
    startMs,
    durationMs
  });
  return {
    el,
    scene,
    cleanup() {
      clearRegisteredTimeline(scene.id);
      el.remove();
    }
  };
}
function tickScene(mount, globalFrame, fps) {
  const local = globalFrame - mount.scene.startFrame;
  if (local < 0)
    return;
  const durationFrames = mount.scene.endFrame - mount.scene.startFrame;
  dispatchTick(mount.el, {
    sceneId: mount.scene.id,
    fps,
    frame: local,
    durationFrames
  });
}
function executeScripts(root, debugLabel = "?") {
  const scripts = Array.from(root.querySelectorAll("script"));
  if (typeof window !== "undefined") {
    window.__execLog = window.__execLog ?? [];
    window.__execLog.push({
      label: debugLabel,
      scriptCount: scripts.length,
      parentChain: scripts.map((s) => !!s.parentNode)
    });
  }
  for (const old of scripts) {
    const fresh = document.createElement("script");
    for (const attr of Array.from(old.attributes)) {
      fresh.setAttribute(attr.name, attr.value);
    }
    fresh.textContent = old.textContent;
    fresh.async = false;
    const parent = old.parentNode;
    if (parent) {
      old.remove();
      parent.appendChild(fresh);
    }
    const body = old.textContent ?? "";
    if (body.trim() && !old.getAttribute("src")) {
      try {
        (0, eval)(body);
      } catch (e) {
        console.error(`[wavelet sceneMount ${debugLabel}] script error:`, e);
      }
    }
  }
}
function resolveUrl(src, base) {
  if (!base)
    return src;
  try {
    return new URL(src, new URL(base, window.location.href)).toString();
  } catch {
    return src;
  }
}

// runtime/wavelet/runtime/src/clipMount.ts
function mountClip(clip, asset, ctx) {
  const url = resolveUrl2(asset.src, ctx.baseUrl);
  const isVideo = asset.kind === "video";
  const el = isVideo ? document.createElement("video") : document.createElement("img");
  el.className = "gm-clip-mount";
  el.src = url;
  el.style.position = "absolute";
  el.style.inset = "0";
  el.style.width = "100%";
  el.style.height = "100%";
  el.style.objectFit = "cover";
  el.style.zIndex = String(ctx.zIndex);
  if (clip.class)
    el.classList.add(...clip.class.split(/\s+/).filter(Boolean));
  if (clip.style)
    el.setAttribute("style", el.getAttribute("style") + ";" + clip.style);
  if (isVideo) {
    const video = el;
    video.playsInline = true;
    video.muted = true;
    video.preload = "auto";
  }
  ctx.viewport.appendChild(el);
  let lastSeekAt = -1;
  return {
    el,
    clip,
    asset,
    tick(globalFrame, fps, playing) {
      if (!isVideo)
        return;
      const video = el;
      const local = globalFrame - clip.startFrame;
      if (local < 0)
        return;
      const target = (clip.sourceInFrame + local) / Math.max(1, fps);
      if (playing) {
        if (video.paused) {
          video.currentTime = target;
          const p = video.play();
          if (p && typeof p.catch === "function")
            p.catch(() => {
              return;
            });
          lastSeekAt = target;
        } else if (Math.abs(video.currentTime - target) > 0.08) {
          video.currentTime = target;
          lastSeekAt = target;
        }
      } else {
        if (!video.paused)
          video.pause();
        if (Math.abs(target - lastSeekAt) > 1 / fps) {
          video.currentTime = target;
          lastSeekAt = target;
        }
      }
    },
    cleanup() {
      if (isVideo) {
        const video = el;
        if (!video.paused)
          video.pause();
      }
      el.remove();
    }
  };
}
function resolveUrl2(src, base) {
  if (!base)
    return src;
  try {
    return new URL(src, new URL(base, window.location.href)).toString();
  } catch {
    return src;
  }
}

// runtime/wavelet/runtime/src/includeMount.ts
async function mountInclude(include, ctx) {
  const el = document.createElement("div");
  el.className = "gm-include-mount";
  el.style.position = "absolute";
  el.style.inset = "0";
  el.style.zIndex = String(ctx.zIndex);
  if (include.class)
    el.classList.add(...include.class.split(/\s+/).filter(Boolean));
  if (include.style)
    el.setAttribute("style", el.getAttribute("style") + ";" + include.style);
  ctx.viewport.appendChild(el);
  const url = resolveIncludeUrl(include, ctx);
  if (!url) {
    el.textContent = `[gm-include: ref="${include.ref}" not found among <gm-composition> decls]`;
    return { el, include, tick: () => {}, cleanup: () => el.remove() };
  }
  if (ctx.ancestry.has(url)) {
    el.textContent = `[gm-include: cycle detected at ${url} — comp already in the include stack]`;
    return { el, include, tick: () => {}, cleanup: () => el.remove() };
  }
  let innerDocEl = null;
  try {
    const res = await fetch(url);
    if (!res.ok) {
      el.textContent = `[gm-include: ${url} → ${res.status}]`;
      return { el, include, tick: () => {}, cleanup: () => el.remove() };
    }
    const html = await res.text();
    const parser = new DOMParser;
    const dom = parser.parseFromString(html, "text/html");
    const found = dom.querySelector("gm-doc");
    if (!found) {
      el.textContent = `[gm-include: ${url} has no <gm-doc> element]`;
      return { el, include, tick: () => {}, cleanup: () => el.remove() };
    }
    innerDocEl = found;
  } catch (e) {
    el.textContent = `[gm-include error: ${e instanceof Error ? e.message : String(e)}]`;
    return { el, include, tick: () => {}, cleanup: () => el.remove() };
  }
  const adoptedDoc = document.importNode(innerDocEl, true);
  adoptedDoc.setAttribute("data-embedded", "");
  adoptedDoc.setAttribute("data-include-ancestry", [...ctx.ancestry, url].join("|"));
  el.appendChild(adoptedDoc);
  return {
    el,
    include,
    tick(localFrame, _fps, _playing) {
      const doc = adoptedDoc;
      if (typeof doc.seekFrame === "function") {
        doc.pause();
        doc.seekFrame(Math.max(0, localFrame));
      }
    },
    cleanup() {
      el.remove();
    }
  };
}
function resolveIncludeUrl(include, ctx) {
  let raw = null;
  if (include.src) {
    raw = include.src;
  } else if (include.ref) {
    const decl = ctx.compositionDecls.find((c) => c.id === include.ref);
    if (!decl)
      return null;
    raw = decl.src;
  }
  if (!raw)
    return null;
  if (!ctx.baseUrl)
    return raw;
  try {
    return new URL(raw, new URL(ctx.baseUrl, window.location.href)).toString();
  } catch {
    return raw;
  }
}

// runtime/wavelet/runtime/src/shaderMount.ts
var VERTEX_SOURCE = `#version 300 es
precision highp float;
out vec2 vUV;
void main() {
  // Full-screen quad from gl_VertexID — no buffers needed.
  vec2 pos = vec2(
    float((gl_VertexID & 1) << 1) - 1.0,
    float((gl_VertexID & 2)) - 1.0
  );
  vUV = (pos + 1.0) * 0.5;
  gl_Position = vec4(pos, 0.0, 1.0);
}
`;
async function mountShader(shader, ctx) {
  const el = document.createElement("div");
  el.className = "gm-shader-mount";
  el.style.position = "absolute";
  el.style.inset = "0";
  el.style.zIndex = String(ctx.zIndex);
  el.style.pointerEvents = "none";
  if (shader.class)
    el.classList.add(...shader.class.split(/\s+/).filter(Boolean));
  if (shader.style)
    el.setAttribute("style", el.getAttribute("style") + ";" + shader.style);
  ctx.viewport.appendChild(el);
  if (shader.lang.toLowerCase() === "wgsl") {
    el.textContent = `[gm-shader lang="wgsl"]: WGSL is not supported in the browser path. Use the native Rust render path for WGSL, or rewrite as GLSL ES 3.00.`;
    el.style.color = "#ff8a8a";
    el.style.fontFamily = "ui-monospace, monospace";
    el.style.padding = "12px";
    return { el, shader, tick: () => {}, cleanup: () => el.remove() };
  }
  let fragSource = shader.inlineSource;
  if (!fragSource && shader.src) {
    try {
      const url = resolveUrl3(shader.src, ctx.baseUrl);
      const res = await fetch(url);
      if (res.ok)
        fragSource = await res.text();
    } catch {}
  }
  if (!fragSource || fragSource.trim().length === 0) {
    el.textContent = `[gm-shader: no source — provide inline GLSL or src="…"]`;
    el.style.color = "#ff8a8a";
    return { el, shader, tick: () => {}, cleanup: () => el.remove() };
  }
  const canvas = document.createElement("canvas");
  canvas.style.width = "100%";
  canvas.style.height = "100%";
  canvas.style.display = "block";
  el.appendChild(canvas);
  const gl = canvas.getContext("webgl2", { premultipliedAlpha: true, alpha: true });
  if (!gl) {
    el.textContent = `[gm-shader: WebGL2 not available in this browser]`;
    el.style.color = "#ff8a8a";
    return { el, shader, tick: () => {}, cleanup: () => el.remove() };
  }
  const resizeCanvas = () => {
    const dpr = window.devicePixelRatio || 1;
    const w = Math.max(1, Math.floor(canvas.clientWidth * dpr));
    const h = Math.max(1, Math.floor(canvas.clientHeight * dpr));
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
      gl.viewport(0, 0, w, h);
    }
  };
  const vert = compileShader(gl, gl.VERTEX_SHADER, VERTEX_SOURCE);
  const frag = compileShader(gl, gl.FRAGMENT_SHADER, fragSource);
  if (!vert || !frag) {
    el.textContent = `[gm-shader: compile failed — check the console for shader log]`;
    el.style.color = "#ff8a8a";
    return { el, shader, tick: () => {}, cleanup: () => el.remove() };
  }
  const program = gl.createProgram();
  if (!program) {
    return { el, shader, tick: () => {}, cleanup: () => el.remove() };
  }
  gl.attachShader(program, vert);
  gl.attachShader(program, frag);
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    const log = gl.getProgramInfoLog(program) ?? "(no log)";
    console.error(`[gm-shader] link failed: ${log}`);
    el.textContent = `[gm-shader: link failed — see console]`;
    el.style.color = "#ff8a8a";
    return { el, shader, tick: () => {}, cleanup: () => el.remove() };
  }
  gl.useProgram(program);
  const uTime = gl.getUniformLocation(program, "uTime");
  const uFrame = gl.getUniformLocation(program, "uFrame");
  const uDuration = gl.getUniformLocation(program, "uDuration");
  const uResolution = gl.getUniformLocation(program, "uResolution");
  const vao = gl.createVertexArray();
  gl.bindVertexArray(vao);
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
  const durationFrames = shader.endFrame - shader.startFrame;
  return {
    el,
    shader,
    tick(globalFrame, _fps, _playing) {
      resizeCanvas();
      const localFrame = Math.max(0, globalFrame - shader.startFrame);
      const t = durationFrames > 0 ? localFrame / durationFrames : 0;
      if (uTime)
        gl.uniform1f(uTime, t);
      if (uFrame)
        gl.uniform1f(uFrame, localFrame);
      if (uDuration)
        gl.uniform1f(uDuration, durationFrames);
      if (uResolution)
        gl.uniform2f(uResolution, canvas.width, canvas.height);
      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    },
    cleanup() {
      gl.deleteProgram(program);
      gl.deleteShader(vert);
      gl.deleteShader(frag);
      gl.deleteVertexArray(vao);
      el.remove();
    }
  };
}
function compileShader(gl, type, source) {
  const shader = gl.createShader(type);
  if (!shader)
    return null;
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    const log = gl.getShaderInfoLog(shader) ?? "(no log)";
    const kind = type === gl.VERTEX_SHADER ? "vertex" : "fragment";
    console.error(`[gm-shader] ${kind} shader compile failed: ${log}`);
    gl.deleteShader(shader);
    return null;
  }
  return shader;
}
function resolveUrl3(src, base) {
  if (!base)
    return src;
  try {
    return new URL(src, new URL(base, window.location.href)).toString();
  } catch {
    return src;
  }
}

// runtime/wavelet/runtime/src/adjustmentMount.ts
function createAdjustmentApplicator(viewport) {
  return {
    apply(active) {
      if (active.length === 0) {
        viewport.style.filter = "";
        viewport.style.backdropFilter = "";
        viewport.style.mixBlendMode = "";
        return;
      }
      const filters = active.map((a) => a.filter).filter(Boolean);
      viewport.style.filter = filters.join(" ");
      const backdrop = lastTruthy(active.map((a) => a.backdrop));
      viewport.style.backdropFilter = backdrop ?? "";
      const blend = lastTruthy(active.map((a) => a.blend));
      viewport.style.mixBlendMode = blend ?? "";
    },
    reset() {
      viewport.style.filter = "";
      viewport.style.backdropFilter = "";
      viewport.style.mixBlendMode = "";
    }
  };
}
function lastTruthy(values) {
  for (let i = values.length - 1;i >= 0; i--) {
    if (values[i])
      return values[i];
  }
  return;
}

// runtime/wavelet/runtime/src/style.ts
var RUNTIME_CSS = `
  /* Data-only elements never render. */
  gm-asset, gm-composition, gm-timeline, gm-track, gm-clip,
  gm-audio, gm-shader, gm-include {
    display: none;
  }

  /* <gm-scene> stays hidden in the original DOM — its content is
     re-mounted into the viewport when active. */
  gm-scene { display: none; }

  /* <gm-adjustment> is metadata only. */
  gm-adjustment { display: none; }

  /* The doc itself is the player host. */
  gm-doc {
    display: block;
    position: relative;
    width: 100%;
    max-width: 100vw;
    background: var(--gm-doc-bg, #000);
    color: var(--gm-doc-fg, #fff);
    font-family: var(--gm-doc-font, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif);
    overflow: hidden;
  }

  .gm-stage {
    position: relative;
    width: 100%;
    aspect-ratio: var(--gm-aspect, 16 / 9);
    background: #000;
    overflow: hidden;
  }

  .gm-viewport {
    position: absolute;
    top: 0;
    left: 0;
    transform-origin: top left;
    /* width/height set by the runtime to the document's resolution. */
    background: #000;
  }

  .gm-scene-mount, .gm-clip-mount {
    pointer-events: none;
  }
  .gm-scene-mount * { pointer-events: auto; }

  .gm-chrome {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 10px 14px;
    background: var(--gm-chrome-bg, rgba(10, 10, 12, 0.92));
    border-top: 1px solid var(--gm-chrome-border, rgba(255, 255, 255, 0.12));
    user-select: none;
  }

  .gm-chrome button {
    appearance: none;
    background: rgba(255, 255, 255, 0.08);
    color: inherit;
    border: 1px solid rgba(255, 255, 255, 0.18);
    border-radius: 6px;
    padding: 6px 10px;
    font: inherit;
    font-size: 13px;
    cursor: pointer;
  }
  .gm-chrome button:hover { background: rgba(255, 255, 255, 0.14); }
  .gm-chrome button:focus-visible { outline: 2px solid #f59e0b; outline-offset: 2px; }

  .gm-scrub {
    flex: 1;
    height: 6px;
    background: rgba(255, 255, 255, 0.12);
    border-radius: 3px;
    position: relative;
    cursor: pointer;
  }
  .gm-scrub-fill {
    position: absolute;
    inset: 0;
    background: var(--gm-accent, #f59e0b);
    border-radius: 3px;
    width: 0%;
    pointer-events: none;
  }
  .gm-time {
    font-variant-numeric: tabular-nums;
    font-size: 12px;
    color: rgba(255, 255, 255, 0.72);
    min-width: 88px;
    text-align: right;
  }
`;
var injected = false;
function injectRuntimeStyle() {
  if (injected || typeof document === "undefined")
    return;
  const tag = document.createElement("style");
  tag.setAttribute("data-wavelet-runtime", "");
  tag.textContent = RUNTIME_CSS;
  document.head.appendChild(tag);
  injected = true;
}

// runtime/wavelet/runtime/src/elements/GamutDoc.ts
class GamutDoc extends HTMLElement {
  resolved = null;
  playhead = null;
  mixer = null;
  stage = null;
  viewport = null;
  chrome = null;
  scrubFill = null;
  timeLabel = null;
  playBtn = null;
  adjustments = null;
  mounts = new Map;
  pending = new Set;
  assetById = new Map;
  resizeObserver = null;
  connectedCallback() {
    injectRuntimeStyle();
    try {
      const parsed = parseFromElement(this);
      this.resolved = resolveTimeline(parsed);
    } catch (e) {
      this.renderError(e instanceof Error ? e.message : String(e));
      return;
    }
    this.assetById = new Map(this.resolved.assets.map((a) => [a.id, a]));
    const embedded = this.hasAttribute("data-embedded");
    if (!embedded)
      this.buildChrome();
    this.buildStage();
    this.scaleViewport();
    this.mixer = new AudioMixer({ fps: this.resolved.fps });
    if (!embedded)
      this.attachPlayhead();
    this.refresh(0);
    this.installResizeObserver();
  }
  disconnectedCallback() {
    this.playhead?.destroy();
    this.playhead = null;
    this.mixer?.destroy();
    this.mixer = null;
    for (const m of this.mounts.values())
      m.cleanup();
    this.mounts.clear();
    this.resizeObserver?.disconnect();
    this.resizeObserver = null;
    this.adjustments?.reset();
    this.adjustments = null;
  }
  play() {
    this.playhead?.play();
    this.mixer?.play();
    this.updatePlayBtn();
  }
  pause() {
    this.playhead?.pause();
    this.mixer?.pause();
    this.updatePlayBtn();
  }
  seekFrame(frame) {
    this.playhead?.seek(frame);
  }
  get currentFrame() {
    return this.playhead?.frame ?? 0;
  }
  get totalFrames() {
    return this.resolved?.durationFrames ?? 0;
  }
  get fps() {
    return this.resolved?.fps ?? 30;
  }
  buildStage() {
    if (!this.resolved)
      return;
    const stage = document.createElement("div");
    stage.className = "gm-stage";
    stage.style.setProperty("--gm-aspect", `${this.resolved.resolution.width} / ${this.resolved.resolution.height}`);
    const viewport = document.createElement("div");
    viewport.className = "gm-viewport";
    viewport.style.width = `${this.resolved.resolution.width}px`;
    viewport.style.height = `${this.resolved.resolution.height}px`;
    stage.appendChild(viewport);
    this.insertBefore(stage, this.chrome);
    this.stage = stage;
    this.viewport = viewport;
    this.adjustments = createAdjustmentApplicator(viewport);
  }
  buildChrome() {
    const chrome = document.createElement("div");
    chrome.className = "gm-chrome";
    chrome.setAttribute("data-print-hidden", "");
    const btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = "▶";
    btn.setAttribute("aria-label", "Play");
    btn.addEventListener("click", () => this.toggle());
    this.playBtn = btn;
    const scrub = document.createElement("div");
    scrub.className = "gm-scrub";
    scrub.addEventListener("click", (e) => this.onScrubClick(e));
    const fill = document.createElement("div");
    fill.className = "gm-scrub-fill";
    scrub.appendChild(fill);
    this.scrubFill = fill;
    const time = document.createElement("div");
    time.className = "gm-time";
    time.textContent = "0:00 / 0:00";
    this.timeLabel = time;
    chrome.appendChild(btn);
    chrome.appendChild(scrub);
    chrome.appendChild(time);
    this.appendChild(chrome);
    this.chrome = chrome;
  }
  attachPlayhead() {
    if (!this.resolved)
      return;
    this.playhead = createPlayhead({
      fps: this.resolved.fps,
      getDurationFrames: () => this.resolved?.durationFrames ?? 0,
      onTick: (frame) => this.refresh(frame),
      onEnd: () => this.updatePlayBtn()
    });
  }
  toggle() {
    if (this.playhead?.playing)
      this.pause();
    else
      this.play();
  }
  updatePlayBtn() {
    if (!this.playBtn)
      return;
    const playing = this.playhead?.playing ?? false;
    this.playBtn.textContent = playing ? "❚❚" : "▶";
    this.playBtn.setAttribute("aria-label", playing ? "Pause" : "Play");
  }
  onScrubClick(e) {
    if (!this.resolved)
      return;
    const rect = e.currentTarget.getBoundingClientRect();
    const ratio = (e.clientX - rect.left) / rect.width;
    const target = Math.round(ratio * (this.resolved.durationFrames - 1));
    this.seekFrame(target);
  }
  refresh(frame) {
    if (!this.resolved || !this.viewport)
      return;
    const tracksByZ = [...this.resolved.tracks].sort((a, b) => a.z - b.z);
    const seen = new Set;
    const activeAdjustments = [];
    const activeAudio = [];
    for (const track of tracksByZ) {
      const zBase = track.z * 1000;
      let itemIdx = 0;
      for (const item of track.items) {
        const within = frame >= item.startFrame && frame < item.endFrame;
        const key = mountKey(track, item, itemIdx);
        itemIdx++;
        if (item.kind === "adjustment" && within)
          activeAdjustments.push(item);
        if (item.kind === "audio" && within)
          activeAudio.push(item);
        if (item.kind !== "scene" && item.kind !== "clip" && item.kind !== "include" && item.kind !== "shader")
          continue;
        if (within) {
          seen.add(key);
          if (!this.mounts.has(key) && !this.pending.has(key)) {
            this.spawnMount(track, item, zBase + itemIdx, key);
          }
          const m = this.mounts.get(key);
          if (item.kind === "include") {
            const local = frame - item.startFrame;
            m?.tick?.(local, this.resolved.fps, this.playhead?.playing ?? false);
          } else {
            m?.tick?.(frame, this.resolved.fps, this.playhead?.playing ?? false);
          }
        }
      }
    }
    for (const [key, m] of this.mounts) {
      if (!seen.has(key)) {
        m.cleanup();
        this.mounts.delete(key);
      }
    }
    this.adjustments?.apply(activeAdjustments);
    this.mixer?.load(activeAudio, this.resolved.assets);
    this.mixer?.seek(frame);
    for (const m of this.mounts.values()) {
      if (m.sceneMount) {
        tickScene(m.sceneMount, frame, this.resolved.fps);
      }
    }
    this.updateScrub(frame);
  }
  spawnMount(track, item, zIndex, key) {
    if (!this.viewport || !this.resolved)
      return;
    if (item.kind === "scene") {
      this.pending.add(key);
      mountScene(item, {
        viewport: this.viewport,
        fps: this.resolved.fps,
        baseUrl: this.baseHrefForRelativeFetches(),
        zIndex
      }).then((mount) => {
        this.pending.delete(key);
        const currentFrame = this.playhead?.frame ?? 0;
        if (currentFrame < item.startFrame || currentFrame >= item.endFrame) {
          mount.cleanup();
          return;
        }
        const itemMount = {
          cleanup: () => mount.cleanup()
        };
        itemMount.sceneMount = mount;
        this.mounts.set(key, itemMount);
        if (this.resolved) {
          tickScene(mount, currentFrame, this.resolved.fps);
        }
      }).catch(() => {
        this.pending.delete(key);
      });
    } else if (item.kind === "clip") {
      const asset = this.assetById.get(item.asset);
      if (!asset)
        return;
      const mount = mountClip(item, asset, {
        viewport: this.viewport,
        baseUrl: this.baseHrefForRelativeFetches(),
        zIndex
      });
      const itemMount = {
        cleanup: () => mount.cleanup(),
        tick: (frame, fps, playing) => mount.tick(frame, fps, playing)
      };
      this.mounts.set(key, itemMount);
    } else if (item.kind === "shader") {
      this.pending.add(key);
      mountShader(item, {
        viewport: this.viewport,
        baseUrl: this.baseHrefForRelativeFetches(),
        zIndex
      }).then((mount) => {
        this.pending.delete(key);
        const currentFrame = this.playhead?.frame ?? 0;
        if (currentFrame < item.startFrame || currentFrame >= item.endFrame) {
          mount.cleanup();
          return;
        }
        const itemMount = {
          cleanup: () => mount.cleanup(),
          tick: (globalFrame, fps, playing) => mount.tick(globalFrame, fps, playing)
        };
        this.mounts.set(key, itemMount);
      }).catch(() => {
        this.pending.delete(key);
      });
    } else if (item.kind === "include") {
      this.pending.add(key);
      mountInclude(item, {
        viewport: this.viewport,
        baseUrl: this.baseHrefForRelativeFetches(),
        zIndex,
        compositionDecls: this.resolved.compositions,
        ancestry: this.includeAncestry()
      }).then((mount) => {
        this.pending.delete(key);
        const currentFrame = this.playhead?.frame ?? 0;
        if (currentFrame < item.startFrame || currentFrame >= item.endFrame) {
          mount.cleanup();
          return;
        }
        const itemMount = {
          cleanup: () => mount.cleanup(),
          tick: (localFrame, fps, playing) => mount.tick(localFrame, fps, playing)
        };
        this.mounts.set(key, itemMount);
      }).catch(() => {
        this.pending.delete(key);
      });
    }
  }
  includeAncestry() {
    const out = new Set;
    const raw = this.getAttribute("data-include-ancestry");
    if (raw) {
      for (const url of raw.split("|")) {
        if (url)
          out.add(url);
      }
    }
    return out;
  }
  baseHrefForRelativeFetches() {
    if (typeof window === "undefined")
      return "";
    return window.location.href;
  }
  updateScrub(frame) {
    if (!this.resolved || !this.scrubFill || !this.timeLabel)
      return;
    const total = this.resolved.durationFrames;
    const ratio = total > 0 ? Math.min(1, frame / Math.max(1, total - 1)) : 0;
    this.scrubFill.style.width = `${(ratio * 100).toFixed(3)}%`;
    this.timeLabel.textContent = `${formatTime(frame, this.resolved.fps)} / ${formatTime(total, this.resolved.fps)}`;
  }
  installResizeObserver() {
    if (typeof ResizeObserver === "undefined" || !this.stage)
      return;
    this.resizeObserver = new ResizeObserver(() => this.scaleViewport());
    this.resizeObserver.observe(this.stage);
  }
  scaleViewport() {
    if (!this.stage || !this.viewport || !this.resolved)
      return;
    const rect = this.stage.getBoundingClientRect();
    if (rect.width === 0)
      return;
    const scale = rect.width / this.resolved.resolution.width;
    this.viewport.style.transform = `scale(${scale})`;
  }
  renderError(message) {
    const pre = document.createElement("pre");
    pre.style.color = "#ff8a8a";
    pre.style.background = "rgba(0,0,0,0.6)";
    pre.style.padding = "12px 16px";
    pre.style.font = "12px ui-monospace, SFMono-Regular, Menlo, monospace";
    pre.style.margin = "0";
    pre.style.whiteSpace = "pre-wrap";
    pre.textContent = `wavelet: ${message}`;
    this.appendChild(pre);
  }
}
function mountKey(track, item, idx) {
  return `${track.id}:${item.kind}:${idx}:${item.startFrame}-${item.endFrame}`;
}
function formatTime(frame, fps) {
  const totalSeconds = Math.max(0, frame) / fps;
  const m = Math.floor(totalSeconds / 60);
  const s = Math.floor(totalSeconds % 60);
  return `${m}:${s.toString().padStart(2, "0")}`;
}

// runtime/wavelet/runtime/src/elements/DataElement.ts
class GmDataElement extends HTMLElement {
}

// runtime/wavelet/runtime/src/runtime.ts
function register() {
  if (typeof customElements === "undefined")
    return;
  injectRuntimeStyle();
  if (typeof window !== "undefined") {
    const existing = window.wavelet;
    window.wavelet = {
      ...existing ?? {},
      onReady,
      onTick,
      registerTimeline
    };
  }
  define("gm-doc", GamutDoc);
  defineData("gm-asset");
  defineData("gm-composition");
  defineData("gm-timeline");
  defineData("gm-track");
  defineData("gm-clip");
  defineData("gm-scene");
  defineData("gm-audio");
  defineData("gm-shader");
  defineData("gm-adjustment");
  defineData("gm-include");
}
function define(name, ctor) {
  if (customElements.get(name))
    return;
  customElements.define(name, ctor);
}
function defineData(name) {
  if (customElements.get(name))
    return;
  customElements.define(name, class extends GmDataElement {
  });
}
register();
export {
  register,
  onTick,
  onReady,
  GmDataElement,
  GamutDoc
};
