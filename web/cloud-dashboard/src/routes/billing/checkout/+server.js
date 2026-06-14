import { redirect } from '@sveltejs/kit';
import { env } from '$env/dynamic/private';

// Polar checkout. SANDBOX BY DEFAULT so the 4242 test card never charges real money
// — flip POLAR_SERVER=production only when going live. Needs (from your Polar account):
//   POLAR_ACCESS_TOKEN   a token for the chosen environment (polar_oat_…)
//   POLAR_PRODUCT_<PLAN>  the product id per plan, e.g. POLAR_PRODUCT_TEAM
// Until those are set, we bounce to settings with a clear "not configured" flag
// rather than erroring — so the rest of the flow is testable without billing.
const HOST = (env.POLAR_SERVER === 'production')
  ? 'https://api.polar.sh'
  : 'https://sandbox-api.polar.sh';

export const GET = async ({ url, request }) => {
  const plan = (url.searchParams.get('plan') || 'team').toUpperCase().replace(/[^A-Z0-9]/g, '');
  const token = env.POLAR_ACCESS_TOKEN;
  const product = env[`POLAR_PRODUCT_${plan}`];

  if (!token || !product) {
    throw redirect(303, '/settings?billing=unconfigured');
  }

  const origin = new URL(request.url).origin;
  const res = await fetch(`${HOST}/v1/checkouts/`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ products: [product], success_url: `${origin}/settings?billing=ok` })
  });

  if (!res.ok) throw redirect(303, '/settings?billing=error');
  const { url: checkoutUrl } = await res.json();
  throw redirect(303, checkoutUrl);
};
