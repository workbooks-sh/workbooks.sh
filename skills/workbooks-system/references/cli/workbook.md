# Workbook commands

Authoring, packaging, signing, querying, and publishing workbooks. Every command
runs in-process (it calls the kernel directly). For the artifact/bundle concept
see `../workbooks.md`; for publishing targets see also `../http.md`.

TOC: parse · bundle/unpack · build/pack · sign/verify · library · storage ·
search · telemetry/ledger · mirror · publish

## Parse a workbook — `work query|tangle|lint <file.org>`

- **Need:** see what an Org workbook contains before building it.
- **Action:** `work query x.org` → headline tree (JSON). `work tangle x.org` → the
  build plan (components/worlds the runtime would execute). `work lint x.org` →
  diagnostics.
- **Success:** pretty JSON on stdout.
- **Failure:** a missing file raises (the command reads the file directly).

## Pack / unpack — `work bundle`, `work unpack`

- **Need:** turn a single Org source into a portable bundle, or take one apart.
- **Action:** `work bundle src.org out` writes a bundle of `{source.org,
  manifest.json}` (the manifest is the tangle plan). `work unpack bundle dest`
  disassembles a parent workbook into a flat tree under `dest`.
- **Success:** `bundled N parts → out` / `unpacked N files → dest`.

## Build / compose — `work build`, `work pack`

- **Need:** compile a workspace's components to WASM, or compose its members.
- **Action:** `work build <workspace>` compiles components → WASM and reports what
  built vs. couldn't (JSON). `work pack <workspace> <out> [--build]` composes the
  members into ONE workbook; `--build` produces the *runnable* projection
  (components compiled to WASM, source dropped).
- **Success:** `packed <slug> → out (N bytes)`.
- **Failure:** a string error from the library layer (e.g. unknown workspace).

## Sign / verify — `work sign`, `work verify`

- **Need:** stamp a published HTML artifact with verifiable provenance, or check
  one you received.
- **Action:** `work sign file.html [--out f]` embeds a did:key manifest (the
  tenant's identity, a `c2pa.action.published` action). `work verify file.html`
  checks signature + asset integrity.
- **Success (verify):** `valid=true signature=… asset_integrity=… issuer=did:…`.

## Library — `work library`, `work checkout`, `work checkin`

- **Need:** see the identity's access graph and move members in/out of a working dir.
- **Action:** `work library` lists workspaces + members. `work library query <sql>`
  runs a cross-workbook query over members' virtual filesystems. `work checkout
  <member> <workdir>` borrows a member out; `work checkin <member> <workdir>` packs
  + signs it back.
- **Success:** a member listing, query JSON, or a checkout/checkin record.

## Durable storage — `work store`, `work stored`, `work fetch`

- **Need:** archive a workspace on the configured backend (local volume / S3 / R2).
- **Action:** `work store <slug> [--build]`, `work stored` (list keys), `work fetch
  <key> <out>`.
- **Success:** `stored <slug> → <key> (backend: …)` / `fetched <key> → out`.

## Recall — `work search`

- **Need:** find relevant content by meaning or text across a library; the files
  ARE the memory (there is no separate store).
- **Action:** `work search <words…> [--semantic|--literal] [--workbook <slug>]`.
  Default is hybrid. Returns up to 8 hits as `workbook/path :: headline` + snippet.
- **Success:** ranked hits, or `(no matches)`.

## Observe a run — `work telemetry`, `work ledger`

- **Need:** inspect what a workflow/agent run did, and prove it wasn't tampered with.
- **Action:** `work telemetry` → all runs (SLUG/STAGE/CALLS/ERRORS/MS). `work
  telemetry <slug>` → one run's stage, tool calls, errors. `work ledger <slug>`
  verifies the run's hash-chained, did-signed `_steps.jsonl`.
- **Success (ledger):** `tamper-evident=ok attributable=ok count=N did=did:…`.
- **Note:** these read run workdirs under `/tmp/bb/<slug>`.

## Source rail — `work mirror`, `work radicle`

- **Need:** push the tenant's git repo to any host, or federate it P2P.
- **Action:** `work mirror <url>` pushes anywhere; `work mirror --forge
  github|gitlab|gitea [--repo n] [--public]` auto-provisions via that forge's
  CLI. `work radicle` publishes over Radicle and returns the `rad:` id.
- **Success:** `mirrored → <url>` / `published → rad:…`.
- **Failure:** `skipped: <reason>` or `error: …`; `radicle: not available` when
  Radicle isn't installed.

## Publish — `work publish`

Render a workbook (.org) → self-contained HTML → a live URL. Declarative, mirrors
deploy-kit. Non-interactive; `--json` switches to machine output (exit 0/non-zero).

- **`work publish init`** — scaffold `./publish.org`. Fails if it exists (use
  `--force`).
- **`work publish validate [config]`** — coherence-check the config, no render/deploy.
- **`work publish apply [<file.org>] [config]`** — render + ship → prints the live
  URL. Workbook defaults to `./workbook.org`, config to `./publish.org`.
- **`work publish site [<dir>]`** — render a multi-page site from `site.org` →
  deploy.

A `publish.org` describes: `PUBLISH_TARGET` (`cloudflare-pages` | `gh-pages` |
`self-hosted` | `desktop-app`), `PUBLISH_PROJECT`, `PUBLISH_DOMAIN`,
`PUBLISH_TITLE`, `PUBLISH_OUTPUT` (default `.publish_out/index.html`). Secrets
(e.g. `CLOUDFLARE_ACCOUNT_ID`) come from ENV, never the file.

- **Success:** `deployed → <url>`. For `desktop-app`: scaffolds a runtime-wired
  Tauri app dir (run `tauri build` to produce the `.app`).
- **Failure modes:** `wrangler not found on PATH` (cloudflare); a non-zero
  wrangler/git exit with the captured output; `unknown PUBLISH_TARGET: …`.
