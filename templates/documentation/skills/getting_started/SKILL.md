---
name: getting_started
description: Author and ship .work workbooks. Use when starting a new workbook, learning the .work format, or onboarding a CLI agent to the work CLI.
---

# Getting started with Workbooks


## What it is

# What is a workbook

A **workbook is a folder of `.work` files** (plus any assets they use). That's the
whole idea. There's no project scaffold to learn, no framework layout to memorize
— a directory of literate documents *is* the application.

## A folder you can hold

Each `.work` file is a [literate document](/introduction/what-is-a-work-file):
prose that explains, and `do … end` blocks that run. Put a few of them in a folder
and you have a workbook — a complete piece of software where the explanation and
the code live in the same place.

Because it's just files in a folder, a workbook moves the way documents move. You
can read it top to bottom, drop it in git, hand it to a teammate, or point an agent
at it — and what they get is the whole thing: interface, logic, data shape, and the
reasons behind all three.

## The four lanes

Everything inside a workbook falls into one of four lanes. You'll meet them
properly in [Anatomy of a .work file](/language/anatomy); here's the shape:

- **Prose** — the rich text that narrates and carries links between ideas.
- **Declaration** — structure with no body: a table, an enum, a record.
- **Code** — a runnable block: a function, a server unit, a browser island.
- **Placement** — the first word of a block says *where* it runs: in the browser
  (`client`), on the engine (`server`), or in a capability sandbox (`sandbox`).

One file can hold all four. That's the point — the thing people see, the code that
makes it work, and the data it stands on don't live in three repositories. They
live in one document.

## How a workbook ships

You don't assemble a workbook by hand. The [`work` CLI](/introduction/what-is-the-work-cli)
operates on the folder: `work weave` folds the tree into one shippable artifact,
`work check` resolves the links between files and audits what each block is allowed
to do, and `work dev` watches the folder and re-weaves as you edit.

The folder is how you organize; the woven artifact is what you ship; the
[Nexus](/introduction/what-is-the-nexus) is what runs it.

That woven artifact is HTML — but HTML here is purely a **build output**, the
format the weave emits because it runs everywhere. It isn't something you author or
configure, and you never hand-write it. You write `.work`; weave produces the HTML.

## Kits and apps

Most workbooks are one of two things. A **kit** is meant to be *imported and
composed* by other workbooks — a shared piece other things build on. An **app** is
the *leaf you launch* — the thing with an interface you actually open. A workbook
can be both: an app that also exports a kit for the next one to use.

You don't have to declare this up front to get started. Make a folder, write a
`.work` file, and you already have a workbook.


# What is a .work file

A `.work` file is a **literate document**: plain prose with runnable blocks mixed
in. It is not a new programming language you have to learn. It's a way to write
[literate programming](/preface/literate-programming) source that compiles the
languages you already use.

## Prose narrates, blocks run

Open any `.work` file and you'll see two things. Paragraphs — ordinary text that
explains what's going on. And blocks — each one opens with a header and ends with
`end`:

server greet :hello do
  def run(name), do: "hello, #{name}"
end

The prose is for the reader. The block runs. That's the whole format.

## The first word names the kind

Every block header reads the same way: **`<kind> [lang] :name … do … end`**.

- The **kind** comes first — it says what this block *is* and where it runs
  (`server`, `client`, `sandbox`, `data`, `def`, `agent`, `resource`, and more).
- The **language** is optional and names what the body is written in.
- The **`:name`** is how other blocks and your prose refer to it.

So `sandbox python :scrape do … end` is a block named `scrape`, running Python,
placed in a capability sandbox. The body inside is real Python.

## Any language we support

A block's body can be written in any of these — and the `work` toolchain compiles
it:

`elixir` · `rust` · `zig` · `c` · `cpp` · `python` · `go` · `js` · `ts` ·
`svelte` · `solid`

This is the lesson that surprises people: you can write a Svelte component in a
`.work` file. The literate document is the authoring surface; the languages inside
are whatever fits the job.

## It's a real tree, not text matching

One quiet but important detail: a `.work` file isn't parsed by guessing with
regexes. The `do … end` block is the delimiter, and a block parses into a real
syntax tree — kind, language, name, and body all come from the structure, not a
pattern match. The same single parse is shared by everything that reads a workbook:
the viewer that highlights it, the tool that maps dependencies between blocks, and
the check that audits capabilities. One source of truth, read the same way every
time.

## Links that hold a workbook together

Inside prose you can reference other things directly: `[[backlinks]]` to other
blocks or pages, `:atoms` and `@types` you mention inline, `#tags`, and `work://`
links across the workbook. These aren't decoration — they're how the document
knits itself into a graph the tools can follow.

Next: see all four lanes laid out in [Anatomy of a .work file](/language/anatomy).



## The work CLI

# What is the work CLI

`work` is the one Workbooks command line — **author, build, run, deploy.** It
operates on a [workbook](/introduction/what-is-a-workbook) folder: it reads the
`.work` tree, folds it into something shippable, and stands up a
[Nexus](/introduction/what-is-the-nexus) to run it. The same `work` binary runs
natively on your machine *and* inside the wasm agent sandbox, so an agent has the
exact tools you do.

## The lifecycle

Working on a workbook follows a simple arc, and each step is one command.

You **author** — write `.work` files, then `work check` to make sure every
reference resolves and every block only does what it's allowed to. `work structure`
lists the units in the tree so you can see what you've got, and `work why`,
`work near`, and `work wit` answer questions about how blocks depend on each other.

You **build** — `work weave` folds the whole folder into one self-contained HTML
artifact. While you're iterating, `work dev` watches the folder and re-weaves on
every change (and hot-swaps into a running Nexus), so the page updates as you type.

You **deploy** — `work deploy` stands up a runtime, local or cloud, from
declarative settings that live with the workbook: scaffold them, validate, apply.

That's the loop: author → build → deploy, all over the same folder.

## Command reference

The CLI groups its verbs the same way:

**author** — read & verify `.work` trees, locally:

- `work check [dir]` — resolve references + audit capabilities
- `work structure [dir]` — list the units in the tree
- `work why / near / wit :unit` — code-graph dependencies + the generated WIT world

**build** — weave & run:

- `work weave <dir> <out>` — weave a tree into one self-contained HTML
- `work graph <dir> <out>` — render the code graph as a workbook
- `work dev <dir>` — watch & re-weave on change (+ Nexus hot-swap)

**deploy** — stand up a runtime, local or cloud:

- `work deploy init | validate | apply` — scaffold · check · deploy the config
- `work deploy verify | status | down` — health · inspect · teardown

**platform** — identity, contexts, the control plane:

- `work ctx · work nexus <url>` — manage targets · point at an engine
- `work login · work whoami` — authenticate · show identity

Every verb also accepts `--json` and `--no-color`. Run `work help` to see the live
surface.

For the deploy story end to end, see
[Deploy: local and cloud](/deploy/deploy-local-and-cloud).


# Get started with your CLI agent

Workbooks is built to be driven by a coding agent — Claude Code, Codex, or whatever
you use. The whole format exists so an agent can read intent and write code in the
same document. This page is the on-ramp for pointing your agent at Workbooks.

## The agent has the same tools you do

The [`work` CLI](/introduction/what-is-the-work-cli) runs natively *and* inside the
wasm agent sandbox. That means your agent isn't working blind against a description
of the tools — it has the real `work check`, `work weave`, and `work dev`, sandboxed
and safe. It can author a workbook, weave it, and see the result, the same way you
would.

## These docs are agent-ready

Everything here is built to hand straight to an agent:

- **Copy as Markdown** — every page has a button that copies its source, ready to
  paste into a chat.
- **Copy as prompt** — wrap a page in a ready-made instruction ("using this
  Workbooks doc, help me…") with one click.
- **`/llms.txt` and `/llms-full.txt`** — a machine-readable index and a full-text
  dump of the whole site, so an agent can ingest the entire documentation at once.

Point your agent at `llms.txt` and it has the map; feed it `llms-full.txt` and it
has the whole book.

## Install the skill

The packaged way to teach your agent the Workbooks workflow is the skill:

npx skills add workbooks-sh/workbooks.sh

That gives your agent the conventions for authoring `.work` files, running the CLI,
and shipping a workbook — so you can describe what you want and let it build.

## How to work with it

The loop is simple: **describe the outcome**, let the agent author the `.work`
files, then **review the rendered workbook** the way you'd review any change —
reading the prose next to the code. Because the document carries its own intent, you
review reasoning and implementation together, in one place.

That's the whole point of everything in these docs: the workbook is legible to you
and to the agent at the same time. Start by
[reading what a workbook is](/introduction/what-is-a-workbook), then put your agent
to work.


