import { authKit } from '@workos/authkit-sveltekit';

// WorkOS redirects here after sign-in (matches WORKOS_REDIRECT_URI = …/v1/auth/callback).
// The SDK exchanges the code, sets the session cookie, and redirects on. No custom OAuth.
export const GET = async (event) => authKit.handleCallback()(event);
