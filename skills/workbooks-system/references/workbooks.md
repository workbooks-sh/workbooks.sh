# Workbooks — the artifact: bundling, unbundling, publishing

## Anatomy

A workbook is one HTML file that is an entire app. Inside it: the interface
(markup/styles/script), the data it carries, its own source (so it can be
unbundled), and — when the app computes — WebAssembly modules executed by an
embedded kernel or by a runtime's wasmtime. Open it anywhere; it does not
need a server to simply be used.

## The three projections

Every buildable workbook exists in three forms; keep them straight:

- **runnable** — what executes and ships: the compiled `.wasm` modules and
  built JS/CSS bundles, embedded in the HTML artifact.
- **source** — what humans and agents read, diff, and edit: the input files
  (components, crates, org documents, configs) on the source rail (git).
- **archive** — both together.

The law that follows: never hand-edit the runnable artifact, and never let
raw build inputs leak into it. If you find yourself editing the compiled
HTML, you are on the wrong projection — unbundle, edit source, rebuild.

## Bundling (source → artifact)

The build step compiles each component with the lane that matches it:

- Compute components (Rust crates, standalone sources) compile to `.wasm`.
- UI projects (Svelte/Vite and similar) build with the project's own
  declared build, and the output bundle is what embeds — the framework is
  not special-cased; the project's `package.json` carries its build.
- Org documents tangle: `:workflow:`/`:component:` headlines become the
  executable plan.

A component whose toolchain is unavailable is reported **unbuilt with a
reason** — the platform never fakes an artifact. Treat an `unbuilt` entry as
a to-do, not an error to suppress.

## Unbundling (artifact → source)

Unbundle reverses the pack: the artifact's embedded source is extracted back
into a project tree you can edit. This is the intended editing loop for any
existing workbook you receive as a file: unbundle → edit source → rebuild →
the new artifact. Round-tripping is a first-class operation; design your
workbooks (and your tooling around them) so nothing breaks under it.

## The authoring loop (CLI)

The `wbx`/workbook tooling drives the loop; the canonical verbs:

```
workbook init        # scaffold a new workbook project
workbook dev         # live-develop against a local engine/preview
workbook build       # bundle: source project -> dist artifact
workbook unbundle    # extract source back out of an artifact
workbook check       # validate the artifact (structure, integrity)
workbook publish     # ship the artifact to a runtime / registry
```

Use `--help` on each rather than memorizing flags; the verbs are the stable
contract.

## Publishing to a runtime

Deploying a workbook to a live engine stores it under an id and serves it on
the public plane:

- `wbx workbook deploy <id> <artifact>` (control plane `PUT /w/<id>`,
  bearer-authed). A complete-HTML artifact is served verbatim; org sources
  are rendered by the runtime.
- **Every deploy is one git commit** in the tenant's repo — the public,
  inspectable changelog (surfaced at the public plane's `/_changes`).
- A static site directory for the app (when present on the engine's data
  volume) serves files directly and takes precedence over the registry —
  that's the multi-path form (a site with subpages/assets) of publishing.

When a workbook needs more than one page or carries assets, publish the
built output tree to the site directory; when it is truly one file, the
registry path is simplest. Either way the source rail (git) is the truth and
the artifact is reproducible from it.
