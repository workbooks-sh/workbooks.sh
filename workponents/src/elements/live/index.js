// workponents · live domain — realtime as a routing config.
//
// The reinvention: presence + pubsub come FREE off the BEAM (Phoenix
// Presence/PubSub) over RCP through the Host socket seam — no provisioned realtime
// backend, no Liveblocks/Pusher account, no schema. The elements bind to ONE
// transport-agnostic `Channel` (`channel.js`) over `this.host`: a real WebSocket
// to the runtime when reachable, a BroadcastChannel MOCK standalone — same
// contract either way, so the elements demo live with no backend and light up
// against the runtime with zero changes. Realtime is config, not infrastructure.
//
// All elements style only from --wb-* tokens, extend WbElement (Lit base), register
// via define(), and reach the channel through the seam (over this.host).
//
//   <work-room>        — the realtime container; joins a topic, slots content.
//   <work-presence>    — who's here (avatars/list/count), live.
//   <work-live-value>  — a shared value (counter/toggle/text) that syncs across clients.
//
// Import this barrel for the whole live set, or a single element file.
export { WorkRoom } from "./work-room.js";
export { WorkPresence } from "./work-presence.js";
export { WorkLiveValue } from "./work-live-value.js";

// The channel seam (also usable standalone by a host wiring its own transport).
export {
  Channel,
  openChannel,
  configureChannel,
  clientId,
  colorFor,
} from "./channel.js";
export { resolveChannel } from "./resolve.js";
