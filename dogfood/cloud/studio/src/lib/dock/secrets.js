// The SECRETS seam — the demo half of Nexus.Secrets. A native CLI never holds its own credential: the host
// injects the secret at invocation (into the guest env / a seeded config file). Here we model that with an
// in-memory store keyed by env-var name, set via `connect <provider> <token>`. NOTHING is persisted to source
// or disk in the demo; in production this reads ONLY through Nexus.Secrets (injected at deploy from the
// encrypted org store), values never authored. This is purely the connection state the runner consults.
const map = {} // ENV_NAME -> token (demo only; production reads via Nexus.Secrets, never authored)

export const secrets = {
  set(env, value) { map[env] = value },
  get(env) { return map[env] || null },
  has(env) { return !!map[env] },
  clear(env) { delete map[env] },
  list() { return Object.keys(map) }
}
