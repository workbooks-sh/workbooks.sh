import { json } from '@sveltejs/kit';
import { authKv, pkceOk } from '$lib/desktopBroker';

// Desktop sign-in, step 3: the app posts {code, code_verifier}. We redeem the one-time
// broker code (deleted on read), enforce S256 PKCE (the app proves it began the flow),
// and return the session bearer — the WorkOS access token the platform verifies via JWKS.
export async function POST({ request, platform }) {
  let body = {};
  try {
    body = await request.json();
  } catch {
    // fall through to the bad-request below
  }

  const code = body.code || '';
  const verifier = body.code_verifier || '';
  if (!code || !verifier) return json({ error: 'bad request' }, { status: 400 });

  const kv = authKv(platform);
  const raw = await kv.get(`cd:${code}`);
  if (!raw) return json({ error: 'exchange failed' }, { status: 400 });
  await kv.delete(`cd:${code}`); // one-time

  const { session, challenge } = JSON.parse(raw);
  if (!(await pkceOk(verifier, challenge))) return json({ error: 'exchange failed' }, { status: 400 });

  return json(session);
}
