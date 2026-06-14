import { listNexuses } from '$lib/api.js';

export async function load() {
  return { nexuses: await listNexuses() };
}
