# Toolkit Releases

The releases-library convention for `toolkits/`. Every toolkit is versioned and
released **independently** — there is no single monorepo-wide toolkit version.

## Versioning scheme

- **Semver per toolkit.** Each `toolkits/<name>/manifest.org` declares its own
  version. `MAJOR.MINOR.PATCH`:
  - **MAJOR** — a breaking change to the toolkit's CLI contract or skill API
    (a skill recipe an agent relied on is removed or behaves differently).
  - **MINOR** — new skills / new CLI surface, backward compatible.
  - **PATCH** — fixes/clarifications to existing skills, no contract change.

- **The version lives in two places, in sync** (the generator keeps them equal):
  1. `#+VERSION:` file keyword — the authoritative, human-edited source.
  2. `:VERSION:` property inside the first `:toolkit:` `:PROPERTIES:` drawer —
     mirrored from the keyword so the runtime's drawer-based `view/1`
     (`runtime/host/toolkits.ex`) surfaces it natively, same as `:CLI_BIN:` /
     `:STATUS:`.

  To bump a toolkit, edit `#+VERSION:` in its `manifest.org`, then run the
  generator (below). Never hand-edit the `:VERSION:` drawer property — it is
  generated.

## Tag format

A cut release is a git tag, scoped per toolkit:

```
<toolkit>-v<x.y.z>        e.g.  ffmpeg-v0.3.0   git-v0.1.0   wraith-v0.2.1
```

This namespacing lets each toolkit move on its own cadence in the shared repo
(and in the mirrored `github.com/workbooks-sh/toolkits` subtree) without tag
collisions.

## The release index — `releases.json`

`toolkits/releases.json` is a **generated** index, keyed by toolkit id:

```json
{
  "ffmpeg": { "version": "0.3.0", "versions": ["0.3.0"], "updated": "2026-06-07" }
}
```

- `version`  — current/latest version (from `#+VERSION:`).
- `versions` — every released version (newest the runtime cares about; grows as
  releases are cut). The runtime reads `releases(root)[id]["versions"]` in
  `runtime/host/toolkits.ex` (`available_versions/3`) to answer
  `work toolkit versions <id>`.
- `updated`  — the manifest's last git-commit date (file mtime fallback).

It is **derived from the manifests** — never hand-edit it. Regenerate with the
generator script and commit the result. CI runs the generator in `--check` mode
and fails the build on drift.

## How a release is cut

1. Make the toolkit change under `toolkits/<name>/` (skills, manifest, CLI wrap).
2. Bump `#+VERSION:` in `toolkits/<name>/manifest.org` per semver.
3. Regenerate the index + drawer property:
   ```
   python3 scripts/gen-toolkit-releases.py
   ```
4. Commit the manifest + `releases.json`.
5. Tag the release:
   ```
   git tag <name>-v<x.y.z>
   git push origin <name>-v<x.y.z>
   ```
   CI on the tag (and on the mirrored toolkits repo) publishes the toolkit at
   that version.

## The live version + rollback

The **live** version of a toolkit (what agents resolve) is, in order:

1. A pin in `toolkits/.live.json` (id → version), if present.
2. Otherwise the in-tree `manifest.org` version (the natural
   "live = what's in tree" default).

`.live.json` is written by the rollback verb and is **local state** — it is not
the source of truth, the manifest + tags are.

Runtime verbs (`runtime/host/toolkits.ex`, surfaced through the `work` CLI):

| Verb                              | What it does                                            |
|-----------------------------------|---------------------------------------------------------|
| `work toolkit version <id>`        | Show the live version of one toolkit.                   |
| `work toolkit live`                | Show the live version of every toolkit.                 |
| `work toolkit versions <id>`       | List all available versions (releases.json ∪ manifest). |
| `work toolkit rollback <id> <ver>` | Pin the live version to a prior released `<ver>`.        |

**Rollback** pins `<id> -> <ver>` in `.live.json` (the version must appear in
that toolkit's `versions`). To return to the tip, remove the pin (or
`rollback` to the current `#+VERSION:`). Rollback never rewrites the tree or the
manifest — it only repoints which released version agents resolve, so it is
instantly reversible.

## Generator

`scripts/gen-toolkit-releases.py`:

- Mirrors each `#+VERSION:` into the `:VERSION:` drawer property (idempotent;
  never clobbers other props).
- Rebuilds `toolkits/releases.json` from the manifests.
- `--check` mode: exits non-zero on any drift (for CI).
