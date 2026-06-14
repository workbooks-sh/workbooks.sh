import { error } from '@sveltejs/kit';
import { getNexus } from '$lib/api.js';

export async function load({ params }) {
  const detail = await getNexus(params.id);
  if (!detail) throw error(404, `Nexus "${params.id}" not found`);
  return detail;
}
