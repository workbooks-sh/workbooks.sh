# CLI bootstrap — `work` vs `workbook`

There are two distinct CLIs. Don't confuse them.

| CLI | What it drives | Where it comes from |
|---|---|---|
| `work` | The Workbooks platform: runtime, toolkits, deploy, dev loop, rt inspection | Elixir escript built from `runtime/host` |
| `workbook` | The standalone single-file artifact lifecycle (`init`/`dev`/`build`/`unbundle`/`publish`/`check`) | The `workbooks-authoring` toolchain |

## Building `work` (canonical)

`work` is the **one** canonical CLI — an Elixir escript from `runtime/host/cli.ex`.
Legacy alternatives (a Rust `work` from the dead substrates monorepo, the npm
`@work.books/cli`) are removed; do not chase them.

```sh
cd runtime
mix deps.get            # first time only
mix escript.build       # produces ./work
# put it on PATH, e.g.:
ln -sf "$PWD/work" /usr/local/bin/work    # or add runtime/ to PATH
work --version
```

Non-interactive hygiene (agent shells alias `-i`):

```sh
export HOMEBREW_NO_AUTO_UPDATE=1
# apt-get -y …   ;   ssh/scp -o BatchMode=yes   ;   cp -f / mv -f / rm -rf
```

## The `workbook` artifact CLI

Provided by the `workbooks-authoring` skill/toolchain. Used inside a workbook
project for the bundle ⇄ unbundle lifecycle. If absent, see that skill for its
install path — it is **not** the same binary as `work`.

## First-run sanity

```sh
work --version          # platform CLI present
work dev info           # demo-env dashboard (runtime target, /health, model key, toolkits root)
```

If `work dev info` reports no runtime, that is fine for authoring/viewing work.
Only stand one up (`work deploy local`) when the task computes.
