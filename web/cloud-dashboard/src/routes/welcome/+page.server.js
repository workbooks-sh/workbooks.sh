import { redirect } from '@sveltejs/kit';

// Mark onboarding complete (1 year). Set BEFORE any Polar redirect so a user
// returning from checkout isn't bounced back into the wizard.
function markDone(cookies) {
  cookies.set('wb_onboarded', '1', { path: '/', maxAge: 60 * 60 * 24 * 365, httpOnly: true, sameSite: 'lax' });
}

export const actions = {
  // Skip / free path → straight to the dashboard.
  finish: async ({ cookies }) => {
    markDone(cookies);
    throw redirect(303, '/');
  },
  // Paid tier → finish onboarding, then hand off to Polar checkout for the chosen tier.
  pay: async ({ request, cookies }) => {
    const tier = String((await request.formData()).get('tier') || 'team').replace(/[^a-z0-9-]/gi, '');
    markDone(cookies);
    throw redirect(303, `/billing/checkout?plan=${tier}`);
  }
};
