import { nexusUsage } from '$lib/api.js';

export async function load() {
  return { usage: await nexusUsage() };
}
