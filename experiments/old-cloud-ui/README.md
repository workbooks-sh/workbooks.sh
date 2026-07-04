# old-cloud-ui — RECOVERED seed for the new cloud/ management dashboard

Recovered from `66f774bc^` (the commit *"remove old cloud v1 island dashboard"* that deleted it when
the heavy Studio SPA took over). This is the ORIGINAL vanilla cloud dashboard — plain `island.work` +
`app.js` + `views/`, **no build step** — that was purely the cloud-infrastructure management surface.

Per RESTRUCTURE.md, the new `cloud/` product wants a SIMPLE "deploy-a-nexus + manage
integrations/keys/voice/SMS" dashboard, not the Slack-style Studio. This is the SEED — it already has the
right surfaces: `views/{nexuses,secrets,inference,runs,data,storage,team,upgrade,workspaces,autopoet,toolkits}.js`.

Not wired to anything. A reference to build the new `cloud/` UI from.
