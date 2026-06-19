import { upsells } from '$lib/upsells.js';
import { nexusUsage } from '$lib/api.js';

export async function load({ fetch }) {
  const [ladder, usage] = await Promise.all([upsells({ fetch }), nexusUsage({ fetch })]);
  return { ladder, currentTier: usage?.capacity?.tier?.id || 'starter' };
}
