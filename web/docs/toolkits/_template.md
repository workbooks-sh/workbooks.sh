
# `===========================================================================`

> <ONE LINE — what this integration lets a workbook or its agent do with <SERVICE>.>
# INTEGRATION PAGE TEMPLATE  (Zapier-style "Workbooks + <Service>")
# -----------------------------------------------------------------------------
# Copy this file to toolkits/<slug>.md and replace every <ALL-CAPS> marker.
# Every section that makes a claim MUST carry a :MATURITY: drawer:
#   ships-today | partial  -> require :EVIDENCE: <path:line> you verified
#   north-star            -> require :CAVEAT: (and NEVER write present tense)
#   wall                  -> require :WALL: bedrock|bridge|forge
# Reference facts (caps, flags, recipe paths) cite :SRC: <path#anchor>.
# Delete every comment line (starting with '#') before publishing.
# `===========================================================================`

# Workbooks + <SERVICE>

- **MATURITY:** <ships-today | partial | north-star>
- _if north-star:  :CAVEAT: <why it is not present-tense yet>_
- _if ships/partial: :EVIDENCE: <toolkits/<slug>/...:LINE you opened>_

<TWO-OR-THREE SENTENCES: the elevator pitch. What service is this, and what does
connecting it to Workbooks unlock? Keep it concrete — name the actual jobs.>

| Field | Value |
| --- | --- |
| Toolkit id | `<slug>` |
| #+EXEC shape | `<command \| task \| posix \| federation>` |
| Backing CLI | `<binary or "—">` |
| Status | `<#+STATUS from manifest>` |
| Manifest | `toolkits/<slug>/manifest.org` |

## What it does

<BULLETED LIST of the concrete capabilities this integration grants. Each bullet =
one job an agent or workbook can do. No marketing adjectives — verbs and nouns.>

- <JOB ONE>
- <JOB TWO>
- <JOB THREE>

## Capabilities it grants

- **MATURITY:** <ships-today | partial>
- **EVIDENCE:** <toolkits/<slug>/...:LINE>
- **SRC:** <toolkits/<slug>/manifest.org#caps>

The `#+CAPS` this toolkit needs from the host. Remember: the host holds the
credential and owns egress — the toolkit never sees the key.

| Capability | Why it needs it |
| --- | --- |
| `<cap>` | <WHAT IT DOES WITH IT> |
| `secrets` | <WHICH CREDENTIAL the host holds> |

See [Dock capabilities](../reference/caps.md) for the exhaustive cap list.

## How to add it

- **MATURITY:** <ships-today | north-star>
- _north-star if the install-from-registry verb isn't live; then add :CAVEAT:_

1. <PREREQUISITE — e.g. "Have a <SERVICE> account and a `<CLI> login`," or
   "Set the `<ENV_VAR>` host secret.">
2. Add the toolkit:
```text
   wbx toolkit add <slug>
```

3. <GRANT step — what cap/credential the host needs, and how it's supplied.>

> **Caution:** <ANY honest caveat about credentials, account selection, or what the user must own themselves. The host never reads or proxies a CLI's own token.>

## Worked example

<ONE concrete end-to-end task. Show the actual command/recipe the agent runs.>

```text
<THE COMMAND OR RECIPE INVOCATION>
```

<WHAT HAPPENS, step by step, and what the user sees at the end.>

## Related toolkits

- <SIBLING TOOLKIT> — [<name>](<slug>.md) (<why you'd pick it instead>)
- <COMPLEMENTARY TOOLKIT> — [<name>](<slug>.md)
- All integrations: [Toolkits & integrations](index.md)

## Maturity

<ONE paragraph, honest. Restate the top-level tier and the single most important
caveat. If north-star, say plainly what is built (the stub / composed primitives)
and what is not. Link the row in the Capability Matrix if one exists.>

- Capability Matrix row: [/maturity](../maturity/index.md)
- Source of truth: `toolkits/<slug>/manifest.org`
