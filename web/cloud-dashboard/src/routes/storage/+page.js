import { listBuckets } from '$lib/api.js';

export async function load({ fetch }) {
  return await listBuckets({ fetch });
}
