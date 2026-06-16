# palette

The WASM build/runtime palette — language runtimes and compilers as pinned, sandboxed commands, held as one toolkit (not separate packages). Each entry is a pinned prebuilt (or build recipe) for a language: fetch + sha-verify + unpack + register as a sandboxed command, so an agent can run untrusted source through it with no OS process and no host access beyond a granted preopen.

## When to reach for it

Reach for `palette` when a workbook or agent needs to run code in a specific language inside the sandbox — Python, Ruby, Go, Lua, a JS engine, or Zig→wasm. It's one install for the whole set, not a per-language package hunt.

## Example

```
work toolkit build palette            # build/register every runtime
work toolkit build palette python     # or just one
python script.py                     # then run untrusted source through it
```

## What it grants

- `qjs` (quickjs-ng JS engine), `python` (CPython 3.12 + stdlib), `ruby` (CRuby 3.3 + stdlib), `go` (yaegi interpreter, `go run`), `lua` (Lua 5.4), `zigdemo` (Zig → wasm authoring).
- Each is a pinned spec; the `.wasm` artifacts are derived (DeployKit fetches them), only the manifests live in git.
- Sandboxed execution with no native OS process — file access only through a granted `--dir` preopen.

## Maturity

Experimental (v0.1.0).
