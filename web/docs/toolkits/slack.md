
# Workbooks + Slack

> Let a workbook or its agent post messages and notify a Slack channel — through a host-brokered webhook, the toolkit never holding the secret.

- **MATURITY:** north-star
- **CAVEAT:** A Slack toolkit is not yet published. The underlying primitive it would stand on — host-brokered outbound HTTP with a host-held secret — ships today (the net/secrets caps in policy.ex). This page describes the intended integration, not a shipped surface.

Connecting Slack would let a workbook (or the agent running it) post a message
or notify a channel — a build finished, an eval regressed, a card moved — by
asking the host to call Slack across the Dock. The credential (an incoming
webhook URL or bot token) is held by the host; the toolkit never sees it and
never opens a socket.

| Field | Value |
| --- | --- |
| Toolkit id | `slack` (planned) |
| #+EXEC shape | `command` |
| Backing CLI | — (HTTP via the Dock) |
| Status | `north-star` |
| Manifest | `toolkits/slack/manifest.org` (planned) |

## What it does

Planned capabilities:

- Post a message to a channel (incoming-webhook path).
- Send a rich/blocks message (bot-token path).
- Notify on a workbook event — build done, eval result, board change.

## Capabilities it grants

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/policy.ex:29
- **SRC:** runtime/host/policy.ex#profiles

The caps this toolkit would need **already exist and ship** — host-brokered network
egress and a host-held secret are defined in `policy.ex` (the `network` profile;
`secrets` is granted from `minimal` up). Only the Slack-specific command wrapper
is unbuilt.

| Capability | Why it needs it |
| --- | --- |
| `net` | The host POSTs to the Slack API / webhook on its behalf |
| `secrets` | The host holds `SLACK_WEBHOOK_URL` / `SLACK_BOT_TOKEN` |

See [Dock capabilities](../reference/caps.md).

## How to add it

- **MATURITY:** north-star
- **CAVEAT:** `wbx toolkit add slack` and the slack command surface are the intended ergonomics. The toolkit is not published; only the brokered net+secrets primitives it would use exist today.

The intended flow:

1. Create a Slack incoming webhook (or a bot token) and store it as a host secret:
```text
   wbx secret set SLACK_WEBHOOK_URL <url>
```

2. Add the toolkit:
```text
   wbx toolkit add slack
```

> **Caution:** The host holds the webhook/token and owns egress. The toolkit asks for a "post to Slack" capability across the Dock — it never reads the secret and never opens its own connection.

## Worked example

The intended end state — an agent posts to `#deploys` when a deploy lands:

```text
wbx slack post --channel '#deploys' --text 'engine deployed to fly · iad'   # planned
```

The host resolves `SLACK_WEBHOOK_URL` from its secret store, POSTs the message,
and returns the result to the toolkit — the credential never crosses the sandbox
boundary. Until the toolkit ships, the same effect is achievable today by
authoring a small `command` toolkit that declares `net + secrets` and calls the
Dock SDK (see [The Dock SDK](../build/dock-sdk.md)).

## Related toolkits

- Workbooks + GitHub — notify on a PR/issue event ([github](github.md))
- Workbooks + Linear — issue sync that could trigger a notification (`toolkits/linear/`)
- Build your own: [Pick a shape](../build/pick-a-shape.md) → [The Dock SDK](../build/dock-sdk.md)
- All integrations: [Toolkits & integrations](index.md)

## Maturity

`north-star`. No Slack toolkit is published. What is real today is the
**foundation** it would stand on — host-brokered network egress plus a host-held
secret (`policy.ex:29`) — which is exactly the safe pattern any author can use
right now to write a one-off Slack `command` toolkit. The dedicated, installable
integration is the documented next step, stated as such, never present tense.

- Capability Matrix row: [/maturity](../maturity/index.md)
- Foundation (ships today): `runtime/host/policy.ex:29`
