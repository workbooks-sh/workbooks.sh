# Deploy local

Authoring and viewing a workbook need **no runtime** — it renders client-side.
Deploy is for standing up the **runtime image** (agents, the compiler lane,
sync) so you can run a workbook against real compute. `work deploy` is the
**user's** tool to run that image — it is **never** a platform-release mechanism.

## Inspect the dev environment first

```sh
work dev info       # runtime target + /health, model key, toolkits root
work dev up         # bring the demo env up
work dev test       # run the suite (= mix test)
```

`work dev info` is the cheap probe: it tells you whether a runtime is already
reachable, the configured model key, and the toolkits root — run it before
deploying anything.

## Zero-config local run

```sh
work deploy local
```

Runs the runtime locally in a krunvm container using the **same OCI image as
prod** — the fastest prod-parity path. No config file needed (like `docker run`).

## The declarative path

For a reproducible, version-controlled deployment, scaffold and reconcile an
HTML deployment descriptor (NOT JSON — it's a `<work-deploy …>` element):

```sh
work deploy init local        # scaffold ./deployment.html (preset: local|cloud)
work deploy validate          # coherence-check it (no apply)
work deploy apply             # reconcile the declared deployment
work deploy status            # current status
work deploy logs              # stream logs
work deploy down              # tear it down
work deploy doctor            # environment preflight
```

The file defaults to `./deployment.html`, so most verbs take no argument. Add
`--json` to any verb for machine-readable output (exit 0 ok / non-zero fail).

## Publish a workbook to a URL

Distinct from deploy: `work publish` renders a workbook (`.html`) to a
self-contained page and ships it to a live URL.

```sh
work publish init             # scaffold ./publish.html
work publish validate         # coherence-check (no render, no deploy)
work publish apply dist/index.html   # render + ship → prints the live URL
work publish site .           # render a multi-page site → deploy
```

> Never await CI to verify a deploy — prove it at the tightest tier
> (`work dev info` → `work deploy local`) that demonstrates the change.
