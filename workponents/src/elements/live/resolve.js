// Shared helper: how a child live element finds its Channel.
//
// Priority: an explicit `topic` attribute (opens the pooled channel directly) →
// else the nearest ancestor <live-room>'s channel. Pooling by topic means both
// paths converge on ONE connection per topic. Returns null if neither resolves
// yet (the caller retries on work-room-state / next frame).
import { openChannel } from "./channel.js";

/** Resolve the Channel for `el` (own `topic` attr, else nearest <live-room>). */
export function resolveChannel(el) {
  const topic = el.getAttribute("topic");
  if (topic) return openChannel(topic);
  let p = el.parentElement;
  while (p) {
    if (p.tagName === "LIVE-ROOM") {
      if (p.channel) return p.channel;
      if (typeof p.join === "function") { p.join(); return p.channel; }
    }
    p = p.parentElement;
  }
  return null;
}
