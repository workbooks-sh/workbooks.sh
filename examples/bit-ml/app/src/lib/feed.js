// The crew feed — the single data source the CrewPanel reads (DESIGN.md §4.8,
// §7). Today it returns SPECIMEN data; the crew runtime is a parallel build
// (epic wb-wc0.2). When that lands, this stub is replaced by a fetch/poll of
// the runtime's public `/_activity` endpoint — same machinery the lander uses,
// extended with per-agent identity.
//
// FUTURE /_activity shape this will consume (do not drift from it):
//   {
//     agents: [
//       { name: 'wren', role: 'writer', doing: 'drafting: deepmind weather', live: true }
//     ],
//     wire: [ { time: '14:01', who: 'wren', msg: 'draft: deepmind-weather.org' } ],
//     pipeline: { assigned: 2, research: 1, writing: 1, edit: 0 }
//   }
//
// Until then `crewFeed()` returns the static specimen below. The CrewPanel
// renders a "specimen data" tag so the placeholder is honest. The component
// maps `live`→ the wire dot and formats `pipeline` to the mono counts string.

export function crewFeed() {
  return {
    specimen: true, // honest flag — flips false once /_activity is wired
    agents: [
      { name: 'wren', role: 'writer',     doing: 'drafting: deepmind weather', live: true },
      { name: 'moss', role: 'research',   doing: 'pulling: nature paper',       live: true },
      { name: 'hale', role: 'editor',     doing: 'idle — next pass in 4m',      live: false },
      { name: 'desk', role: 'assignment', doing: 'thinking',                    live: true },
    ],
    wire: [
      { time: '14:01', who: 'wren', msg: 'draft: deepmind-weather.org' },
      { time: '13:58', who: 'moss', msg: 'research note: 6 sources attached' },
      { time: '13:51', who: 'desk', msg: 'assigned: deepmind weather model' },
    ],
    pipeline: { assigned: 2, research: 1, writing: 1, edit: 0 },
  };
}

// Format the pipeline object into the mono counts string the panel shows:
//   "assigned 2 · research 1 · writing 1 · edit 0"
export function pipelineLine(p) {
  if (!p) return '';
  return `assigned ${p.assigned} · research ${p.research} · writing ${p.writing} · edit ${p.edit}`;
}
