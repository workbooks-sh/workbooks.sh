// Admin bearer authentication middleware.
// Every request to the admin worker requires:
//   Authorization: Bearer <BRANDNANA_ADMIN_KEY>
// The key is stored as a worker secret. Reject 401 if missing or wrong.
// 503 if the secret is not configured (deploy misconfiguration).

import type { MiddlewareHandler } from 'hono';
import type { Bindings } from './env.js';

export const requireAdmin: MiddlewareHandler<{ Bindings: Bindings }> = async (c, next) => {
  const expected = c.env.BRANDNANA_ADMIN_KEY;
  if (!expected) return c.text('admin key not configured', 503);
  const got = (c.req.header('authorization') ?? '').replace(/^Bearer\s+/i, '');
  if (got !== expected) return c.text('unauthorized', 401);
  await next();
};
