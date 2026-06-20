import { redirect } from '@sveltejs/kit';

// /workspace lands on Members & access.
export function load() {
  throw redirect(307, '/workspace/members');
}
