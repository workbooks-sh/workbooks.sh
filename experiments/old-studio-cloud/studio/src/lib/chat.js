// chat.js — real agent conversations. POST /cloud/agent/chat runs the surface's agent synchronously and
// returns its reply { id, title, reply }; sessions carry history. Token-by-token streaming over the SSE
// source /live/agent_run is a later enhancement (chunk #6) — this already gives REAL agent answers.
// Offline (auth.offline) → the caller keeps the believable mock reply, so the standalone demo still runs.
import { api } from './api.js'

export async function sendToAgent({ message, agent, workspace, sessionId, model }) {
  const body = { message, agent, workspace }
  if (sessionId) body.id = sessionId
  if (model) body.model = model
  return api.rt('/cloud/agent/chat', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body)
  }) // → { id, title, reply }
}

export async function loadSessions() {
  try { const r = await api.rt('/cloud/agent/sessions'); return r.sessions || [] } catch (_) { return [] }
}

export async function loadSession(id) {
  try { return await api.rt('/cloud/agent/session?id=' + encodeURIComponent(id)) } catch (_) { return null }
}
