# broker net e2e — proves the SSRF/allow-list egress filter fires at runtime with a REAL wasi:http guest

Build the guest component (StarlingMonkey fetch → wasi:http/outgoing-handler → our send_request override):

    node_modules/.bin/jco componentize test/broker_e2e/net_probe.js \
      --wit test/broker_e2e/net_probe.wit -n net-probe \
      --enable http --enable random --enable clocks -o /tmp/net_probe.component.wasm

Run the DENY-path e2e (offline — denials happen before any connect):

    WB_WEB=0 mix run --no-start test/broker_e2e/deny_e2e.exs

PROVEN: fetch to 169.254.169.254 / 127.0.0.1 → BLOCKED (SSRF floor); fetch to public 8.8.8.8 with
net_allow=["example.com"] → BLOCKED (allow-list, NOT the floor, since 8.8.8.8 is public). Instance survives.
NOT YET PROVEN here: allow-reachability (a listed host actually CONNECTING) — this dev env has no outbound
internet, and the connect path hits an async-runtime panic (env-specific / pre-existing wasmex async). Needs
an internet-enabled env + connect-path investigation (see STATE / bd).
