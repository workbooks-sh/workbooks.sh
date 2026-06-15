import { listBuckets, nexusUsage } from '$lib/api.js';

// The home = the Nexus overview. Pull the org's real storage total + usage rollup
// (the two headline metrics: Storage + Load) server-side; the active nexus itself
// comes from the client store.
export async function load({ fetch }) {
  const [storage, usage] = await Promise.all([listBuckets({ fetch }), nexusUsage({ fetch })]);
  return { storage, usage };
}
