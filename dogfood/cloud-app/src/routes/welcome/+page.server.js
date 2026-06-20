import { redirect } from '@sveltejs/kit';

// Mark onboarding complete (1 year). Set BEFORE any Polar redirect so a user
// returning from checkout isn't bounced back into the wizard.
function markDone(cookies) {
  cookies.set('wb_onboarded', '1', { path: '/', maxAge: 60 * 60 * 24 * 365, httpOnly: true, sameSite: 'lax' });
}

// The onboarding answers, persisted so the dashboard can seed the nexus identity +
// first workspace from what the user told us — instead of generic demo content.
//
// SWAP SEAM: this is the catch-22 stopgap. Today the profile lives in a signed-ish
// cookie because the canonical backend (a Workbooks runtime owning the nexus
// registry) isn't provisioned yet. When the PCP API lands, write the profile to the
// runtime on finish/pay and read it back via $lib/api.js `live()` — the dashboard
// consumes the same shape either way, so only this function changes.
//
// No hosted free tier — a hosted nexus starts at Starter (local nexus = the free path).
const ALLOWED_TIERS = ['starter', 'team', 'scale', 'ent'];
const ALLOWED_ACCOUNT = ['personal', 'org'];
const ALLOWED_DEPLOY = ['', 'local', 'cloud'];
const clip = (s, n) => String(s ?? '').slice(0, n);

function saveProfile(cookies, raw) {
  let p;
  try { p = JSON.parse(raw || '{}'); } catch { p = {}; }
  // Whitelist + clamp every field — this string is round-tripped into a cookie.
  const profile = {
    accountType: ALLOWED_ACCOUNT.includes(p.accountType) ? p.accountType : 'personal',
    deploy: ALLOWED_DEPLOY.includes(p.deploy) ? p.deploy : '',
    orgName: clip(p.orgName, 80), // wire key kept for the contract; carries the nexus name
    orgSize: clip(p.orgSize, 16),
    heard: clip(p.heard, 24),
    firstName: clip(p.firstName, 40),
    region: clip(p.region, 48),
    tier: ALLOWED_TIERS.includes(p.tier) ? p.tier : 'starter',
    usecases: Array.isArray(p.usecases) ? p.usecases.slice(0, 6).map((u) => clip(u, 16)) : []
  };
  cookies.set('wb_profile', JSON.stringify(profile), {
    path: '/', maxAge: 60 * 60 * 24 * 365, httpOnly: true, sameSite: 'lax'
  });
  return profile;
}

export const actions = {
  // Skip / free / local path → persist the profile, then straight to the dashboard.
  finish: async ({ request, cookies }) => {
    saveProfile(cookies, (await request.formData()).get('profile'));
    markDone(cookies);
    throw redirect(303, '/');
  },
  // Paid tier → persist the profile, finish onboarding, hand off to Polar checkout.
  pay: async ({ request, cookies }) => {
    const form = await request.formData();
    const profile = saveProfile(cookies, form.get('profile'));
    const tier = String(form.get('tier') || profile.tier || 'team').replace(/[^a-z0-9-]/gi, '');
    markDone(cookies);
    throw redirect(303, `/billing/checkout?plan=${tier}`);
  }
};
