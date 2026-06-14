import { redirect } from '@sveltejs/kit';

export const actions = {
  // Finish onboarding → mark the user onboarded (1 year) and drop them into the app.
  finish: async ({ cookies }) => {
    cookies.set('wb_onboarded', '1', { path: '/', maxAge: 60 * 60 * 24 * 365, httpOnly: true, sameSite: 'lax' });
    throw redirect(303, '/');
  }
};
