# text — overview

# Overview

  The `text` toolkit wraps the `upper` command — a small, sandboxed WASM binary
  that reads stdin and writes the uppercased text to stdout. An agent reaches for
  it when it needs deterministic string casing/normalization rather than doing it
  by hand in a prompt.

  How an agent runs it: resolve the toolkit (its `:CLI_BIN:` is `upper`), then
  invoke `run-command("upper", input)` through the Dock. There is no OS shell and
  no native binary — the command is itself WASM, capability-gated by the
  Instance's `commands` cap.

  When NOT to use it: anything beyond casing (parsing, templating, regex) is a
  different command/skill. This toolkit is intentionally one narrow transform.

# Skills here
  - `uppercase` — shout / normalize a string to upper case.
