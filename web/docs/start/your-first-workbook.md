
# Your first workbook

> Go from zero to a deployed workbook by directing an agent — no code, one CLI, one happy path.

A **workbook** is a single `.org` file that runs — prose, code, and data in one
artifact that publishes as a live page. You don't have to write it yourself. In
this tutorial you'll stand up a local runtime, *tell an agent what you want in
plain English*, watch it author the workbook for you, and deploy it to a URL.

One happy path, start to finish, about ten minutes. You need a terminal and the
`wbx` CLI — nothing else on your machine. The compilers, the model, and the
sandbox all live **inside** the runtime.

> The CLI is `wbx`. Every command below is real and pinned to where it lives in the
> code. Engine-backed commands (build, agent, deploy) talk to a runtime you start in
> step 2 — they don't need anything else installed.
> :SRC: cli/src/main.rs:24

## 1 · Install the CLI

- **MATURITY:** ships-today
- **EVIDENCE:** web/docs/start/install.md:10
- **SRC:** desktop/scripts/install.sh:4

One line installs the `wbx` binary. The toolchains it needs are **not** installed
here — they live in the runtime as WASM and provision on first use.

```bash
curl -fsSL https://workbooks.sh/install.sh | sh
wbx --help
```

If `wbx --help` prints the verb list, you're ready.

## 2 · Start a runtime

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/deploy/mod.rs:49
- **SRC:** cli/src/deploy/mod.rs#DeployVerb

The agent thinks, compiles, and runs inside a **runtime engine**. `wbx deploy local`
scaffolds a local config if there isn't one, then converges to a running container
on your machine — one command.

```bash
wbx deploy local
wbx deploy status     # confirm it's up
```

`wbx deploy local` is the shorthand: it writes a `deployment.org` if absent, then
applies it (a docker / podman container, or a krunvm microVM on macOS).
:SRC: cli/src/deploy/mod.rs:48

### The runtime needs a model key

- **MATURITY:** ships-today
- **EVIDENCE:** runtime/host/llm.ex:59
- **SRC:** runtime/host/llm.ex#OPENROUTER_API_KEY

For the agent to **think**, the runtime needs one secret: an OpenRouter API key.
You set it as a deployment secret — it lives host-side and the agent never sees
it.

```bash
wbx deploy secrets set OPENROUTER_API_KEY=sk-or-...
wbx deploy apply        # re-converge so the runtime picks it up
```

The key is stored under the name `OPENROUTER_API_KEY`; `wbx deploy secrets list`
shows the names (never the values).
:SRC: cli/src/deploy/mod.rs:60

## 3 · Tell an agent what you want

- **MATURITY:** partial
- **EVIDENCE:** cli/src/main.rs:190
- **CAVEAT:** `wbx agent run` ships and reaches the model today; the agent writing a
- **CAVEAT:** complete, deploy-ready workbook end-to-end from one sentence depends on
- **CAVEAT:** the task and may need a follow-up instruction or two. Treat the result
- **CAVEAT:** as a draft you direct, not a one-shot guarantee.

Describe the workbook in plain English. `wbx agent run` starts a long-horizon run
on the runtime and returns an **id** you poll — the agent works in the background.

```bash
wbx agent run "Make a workbook that shows the current weather \
for three cities I name, with a small chart."
# → returns a run id, e.g. run_a1b2c3
```

Under the hood that's a `POST /api/run` to the engine; the system prompt defaults
to a careful, capable agent, and you can pass `--model` to choose one.
:SRC: cli/src/commands.rs:103

## 4 · Watch it work

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/main.rs:196
- **SRC:** cli/src/commands.rs#agent_status

Poll the run with its id. Repeat until the status shows it's done; the result
includes the workbook the agent authored.

```bash
wbx agent status run_a1b2c3
```

If the draft isn't quite right, tell the agent again in the same plain-English
way with another `wbx agent run` — directing it is the loop. When you're happy,
save the workbook the agent produced as a file, e.g. `weather.org`.

## 5 · Deploy it to a URL

- **MATURITY:** ships-today
- **EVIDENCE:** cli/src/main.rs:206
- **SRC:** cli/src/commands.rs#workbook_deploy

Give the workbook an id and deploy its source to the runtime. It's now live and
listed.

```bash
wbx workbook deploy weather weather.org
# → deployed weather.org → /w/weather
wbx workbook list                         # see it among your deployed workbooks
```

`wbx workbook deploy <id> <file>` reads the org source and `PUT=s it to =/w/<id>`
on the engine — that path is your live workbook.
:SRC: cli/src/commands.rs:120

## What you just did

You installed one CLI, stood up a runtime, **directed an agent in plain English** to
author a workbook, watched it work, and deployed the result to a URL — without
writing the workbook by hand and without a compiler on your machine.

From here:

- **Author one yourself** — scaffold a blank workbook with `wbx init` and edit the
  `.org` directly. See [Your first toolkit](first-toolkit.md) for the build-and-run loop.
- **Understand what a workbook is** → [Workbooks & toolkits](../concepts/two-surfaces.md).
- **Ship it further** → [Publish](../workbooks/publish.md) to the open web.

> North-star: a fully no-terminal version of this — say what you want, get a
> deployed workbook, all inside the desktop app — is where this is heading. Today
> the path above is the real, working one and it runs from a single CLI.
> :SRC: cli/src/main.rs:188

