# Welcome to Workbooks

## What is a Workbook?

A **Workbook** is a single file that the runtime renders, runs, and ships.
There is no "document vs notebook vs app" — the *content* decides. Write a
document, and you get a clean document; add a `:component:` block, and it
becomes live.

### Why it's different

- One file, rendered anywhere — browser or server
- Real compute: source blocks compile to WASM
- Versioned by `git`, shared over Radicle

You can link to things like [the project repo](https://github.com/workbooks-sh/workbooks.sh) inline, and the
renderer handles **emphasis**, *italics*, `code`, and `verbatim` cleanly.

### A small table

| Layer    | Tool     | License |
|----------|----------|---------|
| Render   | renderer | MIT     |
| Runtime  | Wasmex   | MIT     |
| Federate | Radicle  | MIT     |

> The more we let content be self-describing, the more system features dissolve
> into just content.
