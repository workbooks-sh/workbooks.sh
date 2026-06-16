
# Dock capabilities

> The capability reference.

| cap | grants | held by the host |
| --- | --- | --- |
| `vfs` | sandboxed SQLite store | — |
| `commands` | call another registered command | — |
| `llm` | a model completion | the API key |
| `browse` | fetch + extract a URL | the socket |
| `net` | gated outbound HTTP | the socket |
| `parallel` | fan work across isolated instances | — |

A toolkit declares what it needs in `#+CAPS`; importing an ungranted capability
fails to instantiate. See [the Dock & capabilities](../concepts/the-dock.md).
