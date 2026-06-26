// hydrate.js — the bridge that turns the mock store into a live store WITHOUT touching components.
//
// Components read the exported $state collections in data.svelte.js and never fetch. hydrate() opens
// the live-shapes socket (live.js → Nexus.Shapes over /ws) and, per resource, replaces the collection
// on the initial snapshot and upserts/removes on each delta. Svelte 5 $state proxies re-render every
// consumer on in-place mutation, so wiring is purely additive — the seed arrays just become the
// starting value until the server's snapshot lands.
//
// Offline (no runtime): the socket never connects, no snapshot arrives, and the mock seed data stays —
// so the same build runs as the live dashboard (with a nexus) and the standalone demo (without one).
import { live } from './live.js'
import { surfaces, workspaces, messages, dms, folders } from './data.svelte.js'

// shape name (registered server-side via Nexus.Shapes.register) → the local $state collection
const SHAPES = {
  surfaces,
  workspaces,
  messages,
  dms,
  folders
}

// replace the contents of a $state array in place (keeps the same proxy, re-renders consumers)
function replaceAll(arr, rows) {
  arr.splice(0, arr.length, ...rows)
}

// upsert-by-id (idempotent — a delta that echoes an optimistic local write replaces, never duplicates)
function upsert(arr, row) {
  const i = arr.findIndex((x) => x.id === row.id)
  if (i >= 0) Object.assign(arr[i], row)
  else arr.push(row)
}

function remove(arr, row) {
  const i = arr.findIndex((x) => x.id === row.id)
  if (i >= 0) arr.splice(i, 1)
}

let started = false

// Open the live socket and subscribe every shape. `scope` (workspace/channel) can narrow a shape;
// omitted here means "everything in the tenant" (the socket is tenant-scoped server-side).
export function hydrate() {
  if (started) return
  started = true
  const client = live()

  for (const [name, arr] of Object.entries(SHAPES)) {
    client.subscribeShape(name, undefined, {
      init: (rows) => { if (rows && rows.length) replaceAll(arr, rows) },
      delta: ({ op, row }) => {
        if (op === 'insert' || op === 'update') upsert(arr, row)
        else if (op === 'delete') remove(arr, row)
      }
    })
  }
}
