import { nexusUsage } from '$lib/api.js';

export async function load({ fetch }) {
  return { usage: await nexusUsage({ fetch }) };
}
