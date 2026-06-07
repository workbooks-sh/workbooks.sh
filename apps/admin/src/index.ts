// Brandnana admin worker — admin.brandnana.net
//
// Exposes internal cost / rate-card / event-log endpoints for Claude + operators.
// Every route requires Authorization: Bearer <BRANDNANA_ADMIN_KEY>.
//
// Routes:
//   GET  /health    — liveness + binding probe
//   GET  /spend     — cost / revenue / profit aggregate
//   GET  /rates     — vendor + customer rate cards
//   POST /rates     — create untagged draft customer rate card
//   POST /rates/:id/tag  — freeze a draft with a tag
//   GET  /events    — paginated event log
//   POST /simulate  — dry-run verb cost projection

import { Hono } from 'hono';
import { requireAdmin } from './auth.js';
import type { Bindings } from './env.js';
import eventsRoute from './events.js';
import ratesRoute from './rates.js';
import simulateRoute from './simulate.js';
import spendRoute from './spend.js';

const app = new Hono<{ Bindings: Bindings }>();

// All routes require admin bearer auth.
app.use('*', requireAdmin);

// ── Health ────────────────────────────────────────────────────────────────────

app.get('/health', async (c) => {
  let dbStatus: 'ok' | 'error' = 'ok';
  try {
    await c.env.DB.prepare('SELECT 1').first();
  } catch {
    dbStatus = 'error';
  }

  return c.json({
    service: 'brandnana-admin',
    status: 'ok',
    bindings: { DB: dbStatus },
  });
});

// ── Sub-routes ────────────────────────────────────────────────────────────────

app.route('/spend', spendRoute);
app.route('/rates', ratesRoute);
app.route('/events', eventsRoute);
app.route('/simulate', simulateRoute);

export default app;
