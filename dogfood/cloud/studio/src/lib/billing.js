// billing.js — billing & payments data + actions for the OWNER (the single billing manager per nexus).
// Live (real endpoints) vs demo (auth.offline → fixtures), same two-mode pattern as you.js. Sources:
//   • subscription/plan        GET  /cloud/billing            → { configured, server, subscription }
//   • inference credits/ledger GET  /cloud/inference          → { balance, spent_mtd, default_model, models, pricing }
//   • capacity/usage           GET  /api/platform/usage       (Nexus.Capacity.report)
//   • tier ladder              GET  /api/platform/tiers       → { tiers }
//   • upgrade/subscribe        POST /cloud/billing/checkout   → { url } | { pending, message }
//   • credit top-off           POST /cloud/inference/topup    → { url } | { pending, total, message }
// Checkout/top-up either hand back a Polar checkout URL (redirect) or a `pending` notice when Polar isn't
// configured on this nexus — the UI surfaces both honestly (no fake "success").
import { api } from './api.js'

export async function loadBilling(offline) {
  if (offline) return demoBilling()
  const out = { billing: { configured: false }, inference: null, usage: null, tiers: [] }
  try { out.billing = await api.rt('/cloud/billing') } catch (_) {}
  try { out.inference = await api.rt('/cloud/inference') } catch (_) {}
  try { out.usage = await api.plat('/usage') } catch (_) {}
  try { const t = await api.plat('/tiers'); out.tiers = t.tiers || t || [] } catch (_) {}
  return out
}

const post = (path, body) =>
  api.rt(path, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })

// Returns { url } (caller redirects to Polar) or { pending, message } (billing not configured here).
export async function startCheckout(tier, offline) {
  if (offline) return { pending: true, message: 'Checkout is disabled in the demo.' }
  return post('/cloud/billing/checkout', { tier, success_url: location.href })
}

export async function topUp(amount, offline) {
  if (offline) return { pending: true, message: 'Top-ups are disabled in the demo.' }
  return post('/cloud/inference/topup', { amount, success_url: location.href })
}

// money/format helpers
export const usd = (n) => '$' + (Number(n) || 0).toFixed(2)

function demoBilling() {
  return {
    billing: { configured: true, server: 'sandbox', subscription: { tier: 'pro', status: 'active' } },
    inference: { provider: 'Workbooks Inference', balance: 42.5, spent_mtd: 7.2,
      default_model: 'anthropic/claude-opus-4.8',
      pricing: { cloudflare_pct: 5.0, workbooks_pct: 0.5, note: 'Provider rates, no per-token markup; top-ups carry fees.' } },
    usage: { plan: 'pro', state: 'running' }, tiers: []
  }
}
