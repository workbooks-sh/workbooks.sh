# Workbook Bundle — Inferred Adjacents & Security Items

Companion to `WORKBOOK-BUNDLE.md`. The egress migration (separate `.wbundle` →
embedded self-contained `.html`) surfaced a set of INFERRED items that belong to
the same boundary. Status as of the embedded-egress landing.

## Security (the floor that ships WITH the migration)

| # | Item | Severity | Status |
|---|------|----------|--------|
| 1 | **Zip-bomb / decompression-ratio guard** — a few-KB base64 zip can inflate to GBs and OOM the host BEAM (`:zip.extract`), the agent sandbox, or a browser tab. | HIGH | **DONE.** `Bundle.unpack` caps total uncompressed (512 MB) + per-entry ratio (200×) from `:zip.list_dir` BEFORE extracting. JS loader mirrors the caps from the central dir AND re-checks actual inflated size per entry. Tests: `bundle_egress_migration_test.exs`, `web/wb-bundle-loader.test.js`. |
| 2 | **Zip-slip path traversal** — entry names like `../../etc/x` or absolute paths written to disk by `wb unbundle` / `Library.unpack`. | HIGH | **DONE.** `Library.unpack` routes through `Bundle.write_tree` (`safe_member?` rejects absolute / `..`); `wb unbundle` already did. Tests: `bundle_cli_test.exs`, `bundle_egress_migration_test.exs`. |
| 3 | **Signature/provenance binding on the new form** — once the zip is embedded, the signed bytes change; a recipient could swap the wb-bundle payload under a valid-looking signature. | MEDIUM-HIGH | **DONE.** `Manifest.sign`/`verify` hash the page with the wb-bundle block stripped (invariant under embed/extract) and preserve it in the signed output; the embedded zip is bound by a signed `wb.bundle.sha256` assertion. `Bundle.verify/1` returns `bundle_integrity: false` on a swap. Tests: `bundle_egress_migration_test.exs`. |
| 4 | **CSP + inert payload on served pages** — embedded HTML/JS/.wasm in the hydrated VFS must not auto-execute with the page's origin. | HIGH | **DONE.** `PublicWeb.serve_html` sets a `Content-Security-Policy`; hydrated entries are data until the runtime explicitly evaluates them; `wb-bundle` is `type=application/zip` (non-executable). |
| 5 | **Privacy leak of session/private files** on the raw-tree `wb bundle <dir>` egress. | MEDIUM | **DONE.** `Bundle.read_tree` consults `Workbooks.Private.private?/1` (the one public/private boundary), stripping secrets / agent-memory / session sidecars. Tests: `bundle_egress_migration_test.exs`. |
| 6 | **Sealed-entry key escrow on the embedded form** — embedding ciphertext into a freely-shared `.html` must still route key release through the runtime gate; manifest `key_refs` must survive embed/extract. | MEDIUM | **DONE.** `ship(egress: :html)` seals the FILESYSTEM entries (the page is the unsealable carrier); the sealed envelopes + `key_refs` live in the embedded zip and survive `read_any` → `open` unchanged (no key is ever inlined). Existing `web_key_release_test.exs` passes against the new default. |
| 7 | **Decompression-side SSRF/fetch** from hydrated entries triggering network. | LOW-MEDIUM | **No change needed** — the existing `NetGuard` SSRF floor (`js_dock.ex`) already governs all bundle-originated brokered requests; bundles add no new net surface. |
| 8 | **base64 break-out / nested `</script>`** terminating extraction early. | LOW | **Verified safe** — base64 excludes `<` (pinned by `bundle_embed_test.exs`); the `@bundle_re` `.*?` is non-greedy but the alphabet guarantee means a payload cannot contain `</script>`. |

## Workbook-spec / wb-bundle coexistence

A single `.html` may carry `<script id=workbook-spec>`, a `wb-c2pa-manifest`
signature block, AND `<script id=wb-bundle>`. **Resolved:** `Manifest.sign` strips
ONLY the prior c2pa manifest before re-injecting (preserving both the wb-bundle and
any workbook-spec marker); `embed`'s `strip_bundle` touches ONLY the wb-bundle block.
So the three coexist; the spec marker desktop relies on for format detection is never
clobbered.

## Idempotent re-bundle / source-of-truth

`embed/2` strips a prior bundle before re-embedding (idempotent). The page
source-of-truth is the **org** in the tree: the `bundle` CLI verb re-renders the page
from `source.org`/`workspace.org` when there's no built `index.html`, and `tangle_files`
re-derives native from the org on every rebuild — so re-bundling never stacks stale
page html. `Library.pack`'s `page_html/1` follows the same precedence
(`index.html` → `workbook.html` → rendered org).

## Deferred / belongs to another layer (NOT in this runtime change)

These are inferred-adjacent but live in the desktop or are intentionally deferred;
tracked here so they aren't lost:

- **Desktop unbundle UX** — overwrite/confirm when the target dir exists,
  reveal-in-finder on success (`fs_ops::fs_reveal`), progress for large bundles, and a
  "bundle" affordance from a working dir in the file tree. Lives in
  `desktop/.../workbook_io.svelte.ts`, not the runtime.
- **Streaming for large bundles in the browser** — `atob` of a multi-MB base64 block
  is memory-heavy; chunked decode and/or a server-side hydrate fallback for very large
  archives. The embedded-form SIZE BUDGET is enforced by the zip-bomb cap (item 1); the
  streaming optimization itself is deferred (noted in `WORKBOOK-BUNDLE.md` "Publish/serve").
