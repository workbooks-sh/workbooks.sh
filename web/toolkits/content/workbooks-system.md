# workbooks-system

System knowledge for an agent running *inside* a Workbooks runtime: what a workbook / runtime / toolkit / workflow is, the WASM-only rules of engagement, how to author and publish from the agent's seat, and the product facts to get right when writing about Workbooks. It carries no new binary — `wb` is already host-provided on PATH — only the org skill files that teach the agent the platform it lives in.

## When to reach for it

Add `workbooks-system` to any agent that needs to reason about the platform it's running on — to author or publish workbook content, discover and use a capability, drive a board/lifecycle, or write accurate prose about Workbooks.

## Example

```
# the agent's reality this toolkit is written for:
#  - one tool surface: a WASM-sandboxed shell; capabilities arrive as commands on PATH
#  - WASM commands only — no node/python/cargo/native; new needs go through a compiler lane
#  - files via vfs_read / vfs_write; the workdir is a tenant git repo
#  - wb available in-process; network only when granted, via a curl-like fetch
```

## What it grants

- `overview`, `concepts` (what *is* a workbook/runtime/toolkit/workflow/Dock), `authoring`, `toolkits`, `workflows`, and `writing` skills.
- The invariants an in-runtime agent must not break, and the line between in-runtime work and host/operator work (provisioning, image builds, `wb deploy`, cloud lifecycle — out of scope).

## Maturity

Experimental (v0.1.0). `wb` is host-provided — every Workbooks engine fulfills it in-process, tenant-scoped; the toolkit bundles no binary by design. If `wb` is unavailable, you are not on a Workbooks runtime.
