import { listBuckets } from '$lib/api.js';

export async function load() {
  return await listBuckets();
}
