// ── UPSELLS — the canonical "where you are → where you can go" ────────────────
// One nexus per org: you SCALE the one nexus, you never create several. The only
// real constraints are MEMORY (RAM) and BANDWIDTH/STORAGE — workspaces and users
// are effectively unlimited (any user cap is generous enough not to bind). Upgrading
// your account = scaling your nexus to the next stage.
//
// This is the single source the upgrade interface (/upgrade) and every "Scale up"
// affordance read. Keep it simple for now; the full per-stage MARKETING PAGES grow
// from here later. Tier limits come live from the control plane (`/tiers`); the
// stage framing + unlock bullets live here.
import { listTiers } from '$lib/api.js';

// Per-stage marketing framing, keyed by tier id (limits/price come from /tiers).
const STAGE = {
  starter: { tag: 'Start', headline: 'Free to start', pitch: 'Everything to build and ship your first workbooks — free.' },
  team: { tag: 'Grow', headline: 'For growing teams', pitch: 'More memory and bandwidth, plus your own custom domain.' },
  scale: { tag: 'Scale', headline: 'For scale', pitch: 'Serious memory and bandwidth for heavy, always-on workloads.' }
};

// What moving UP to each tier unlocks vs the one below — the upsell bullets.
const UNLOCKS = {
  team: ['4× the memory', '10× the bandwidth & storage', 'Custom domains', 'Priority support'],
  scale: ['4× more memory again', '10× more bandwidth & storage', 'Dedicated capacity']
};

// Used if the control plane is unreachable — mirrors Nexus.Pricing so the page never blanks.
const FALLBACK = [
  { id: 'starter', name: 'Starter', ram_mb: 1024, storage_gb: 10, price: 0, 'domains?': false },
  { id: 'team', name: 'Team', ram_mb: 4096, storage_gb: 100, price: 49, 'domains?': true },
  { id: 'scale', name: 'Scale', ram_mb: 16384, storage_gb: 1000, price: 199, 'domains?': true }
];

const ram = (mb) => (mb >= 1024 ? `${mb / 1024} GB` : `${mb} MB`);

/** The canonical upsell ladder — live tier limits fused with stage framing. */
export async function upsells(opts = {}) {
  let tiers = [];
  try { tiers = await listTiers(opts); } catch {}
  if (!tiers.length) tiers = FALLBACK;

  return tiers.map((t) => ({
    id: t.id,
    name: t.name,
    ...STAGE[t.id],
    price: t.price,
    priceLabel: t.price ? `$${t.price}/mo` : 'Free',
    memory: ram(t.ram_mb),
    bandwidth: `${t.storage_gb} GB`,
    domains: t['domains?'] ?? t.domains ?? false,
    unlocks: UNLOCKS[t.id] || [],
    // Every stage carries the same uncapped promise — the constraint is memory + bandwidth.
    unlimited: ['Unlimited workspaces', 'Unlimited users', 'Zero-egress storage', 'Postgres included']
  }));
}

/** The upsell to show given the current tier id — the next stage up, or null at the top. */
export function nextUpsell(ladder, currentId) {
  const i = ladder.findIndex((t) => t.id === currentId);
  return i >= 0 ? ladder[i + 1] || null : ladder[1] || null;
}
