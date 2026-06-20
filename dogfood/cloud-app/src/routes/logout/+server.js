import { authKit } from '@workos/authkit-sveltekit';

// Clear the session + redirect to WorkOS logout. Public route (the gate lets it through).
export const GET = async (event) => authKit.signOut(event);
