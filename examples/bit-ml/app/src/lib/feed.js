// The crew feed — the data source the CrewPanel reads (DESIGN.md §4.8, §7).
// Two surfaces: the CREW activity (agents + doing + live) and the COMMIT
// history (the newsroom's changes). Live, both come off the runtime's public
// endpoints — `/_activity` (crew shape) and `/_changes` (commits), the same
// machinery the lander uses. Offline, `crewFeed()` returns the SPECIMEN below
// and the panel shows the honest "specimen data" tag.
//
// /_activity shape this consumes (do not drift):
//   {
//     agents: [
//       { name:'wren', role:'writer', doing:'drafting: deepmind weather',
//         live:true, avatarSeed:'wren' }
//     ],
//     wire: [ { time:'14:01', who:'wren', msg:'draft: deepmind-weather.md' } ],
//     pipeline: { assigned:2, research:1, writing:1, edit:0 }
//   }
//
// /_changes shape (the full commit history, newest first):
//   { commits: [ { sha:'a1b2c3d', author:'wren', msg:'write: deepmind-weather',
//                  ts: 1718031660 } ] }     // ts = unix seconds (optional)
//
// `avatarSeed` (defaults to name) drives the OpenPeeps avatar (LOCAL pack now —
// see DESIGN.md §4.8a). `desk` is the assignment lead.

// ── crew bios — one honest sentence each, from agents/*.html role descriptions.
// No fabrication: these describe what the agent literally does in the newsroom.
export const BIOS = {
  desk: 'Decides what bit.ml covers — scans the wire and assigns each story with an angle and real, found leads. Never writes.',
  moss: 'The researcher. Builds the factual skeleton from primary sources, every load-bearing fact pinned to a URL, and names the gaps it could not verify.',
  wren: 'The writer. Turns the skeleton into the bite — only the skeleton’s facts, made to read well. Decides if a story earns a banner.',
  hale: 'The editor, adversarial by job. The last gate before readers: traces every claim to a fact, cuts what isn’t earned, then publishes.',
};

export function crewFeed() {
  return {
    specimen: true, // honest flag — flips false once /_activity is wired
    // desk first — it's the assignment lead; the next three (moss · wren · hale)
    // are its reports.
    agents: [
      { name: 'desk', role: 'assignment', doing: 'assigning: deepmind weather', live: true,  avatarSeed: 'desk' },
      { name: 'moss', role: 'research',   doing: 'pulling: nature paper',       live: true,  avatarSeed: 'moss' },
      { name: 'wren', role: 'writer',     doing: 'drafting: deepmind weather',  live: true,  avatarSeed: 'wren' },
      { name: 'hale', role: 'editor',     doing: 'next pass in 4m',             live: false, avatarSeed: 'hale' },
    ],
    wire: [
      { time: '14:01', who: 'wren', msg: 'draft: deepmind-weather.md' },
      { time: '13:58', who: 'moss', msg: 'research note: 6 sources attached' },
      { time: '13:51', who: 'desk', msg: 'assigned: deepmind weather model' },
    ],
    pipeline: { assigned: 2, research: 1, writing: 1, edit: 0 },
  };
}

// The full commit history the console + profile read (offline specimen). Live,
// this is replaced by /_changes. sha/author/msg, newest first; ts optional.
export function changesFeed() {
  return {
    specimen: true,
    commits: [
      { sha: 'a1b2c3d', author: 'wren', msg: 'write: deepmind-weather.md — ten-day forecast on one TPU', ts: tsAgo(120) },
      { sha: '9f3e21a', author: 'moss', msg: 'research: deepmind-weather — 6 facts, 6 sources, gaps: contract names', ts: tsAgo(540) },
      { sha: 'c7d4e90', author: 'hale', msg: 'edit: tsmc-arizona — cut two overclaims, dek tightened', ts: tsAgo(900) },
      { sha: '4a8b1f2', author: 'desk', msg: 'desk: assigned deepmind weather model — angle: the supercomputer it replaced', ts: tsAgo(1320) },
      { sha: 'e21c5d8', author: 'hale', msg: 'publish: tsmc-arizona — the fab that finally taped out', ts: tsAgo(1800) },
      { sha: 'b90a3c4', author: 'wren', msg: 'write: tsmc-arizona — yields, the timeline, who waited', ts: tsAgo(2400) },
      { sha: '5f7e0b1', author: 'moss', msg: 'research: tsmc-arizona — 4 facts, 5 sources, gaps: none', ts: tsAgo(3000) },
      { sha: '1c2d3e4', author: 'desk', msg: 'desk: groomed board — killed 2 stale, merged duplicate chip leads', ts: tsAgo(3600) },
    ],
  };
}

function tsAgo(s) { return Math.floor(Date.now() / 1000) - s; }

// Format the pipeline object into the mono counts string the panel shows:
//   "assigned 2 · research 1 · writing 1 · edit 0"
export function pipelineLine(p) {
  if (!p) return '';
  return `assigned ${p.assigned} · research ${p.research} · writing ${p.writing} · edit ${p.edit}`;
}

// ── live pollers ────────────────────────────────────────────────────────
// Both try the local endpoint then the deployed fallback; return null on miss
// (the caller keeps showing the specimen + its honest tag). Short timeout so a
// dead endpoint never stalls the panel.
const CHANGES_URLS  = ['/_changes',  'https://bit-ml-live.fly.dev/_changes'];
const ACTIVITY_URLS = ['/_activity', 'https://bit-ml-live.fly.dev/_activity'];

async function fetchFirst(urls) {
  for (const url of urls) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(6000) });
      if (res.ok) return await res.json();
    } catch { /* next */ }
  }
  return null;
}

// Returns the /_activity crew payload, or null when offline.
export async function fetchActivity() {
  const j = await fetchFirst(ACTIVITY_URLS);
  if (!j || !Array.isArray(j.agents)) return null;
  return { specimen: false, agents: j.agents, wire: j.wire ?? [], pipeline: j.pipeline ?? null };
}

// Returns { commits } from /_changes, or null when offline. Tolerates either
// {commits:[…]} or a bare array.
export async function fetchChanges() {
  const j = await fetchFirst(CHANGES_URLS);
  const commits = Array.isArray(j) ? j : j?.commits;
  if (!Array.isArray(commits)) return null;
  return { specimen: false, commits };
}
