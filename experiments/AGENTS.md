# experiments/ — pet projects & spikes, NOT production

Everything in this folder is an **experiment**: a pet project, a spike, an old
attempt, or something not yet relevant to the shipped products. It lives here so
it can't be confused with — or accidentally coupled to — the real product roots
(`tiny-lasers`, `nexus`, `cli`, `compilers`, `autopoet`, `cloud`).

## Rules
- **No product root may depend on anything in here.** (CI enforces the dependency DAG.)
- Treat anything here as unsupported and possibly broken.
- If something here becomes a real product surface, it **graduates OUT** to its own root.

## Contents
- `autopoet-chamber/` — Autopoiesis v3 learning-system spike (giving autopoet plasticity/attention)
- `nexus-spikes/` — one-off eval / orchestration `.exs` scripts
- `templates/`, `sites/`, `scratch/` — stale scaffolding
- (later) `wasm-video/` — the wavelet video renderer (alive, worked on occasionally)
- (later) `studio/` — the deprecated Slack-style cloud dashboard (superseded by the new cloud mgmt UI)
