# Run a `work-src` — the compiler lane

Logic in a workbook is written **inline** as a `<work-src>` source block. The
**Dock** (the host capability seam) compiles it to WASM. The browser runs the
result. There is no native execution — every dependency becomes a
capability-gated WASM command.

## Author the block

```html
<work-src lang="rust">
  fn main() { println!("hello from wasm"); }
</work-src>
```

`lang` may be `rust`, `c`, `zig`, `python`, or `js` (the compiler/interpreter
itself runs in WASM). The block's text is the source.

## Drive the compiler lane

```sh
work compiler              # or: work compiler list — languages the Dock builds
work compiler build rust   # build the in-WASM compiler for the language
work compiler run rust src/main.rs   # compile + run a source file → WASM
```

- `work compiler build <lang>` provisions the language's WASM compiler (mrustc
  for Rust, clang for C, zig, etc. — all in-sandbox).
- `work compiler run <lang> <file> [args…]` compiles a source file and runs the
  resulting WASM, printing its output.

> Compiled langs (C / Zig / Rust) go through `work compiler …`. Interpreted langs
> (python / js / …) are already in-sandbox and run directly through the same lane.

## Promote inline source into a reusable command

When a `<work-src>` block earns a name, lift it into a kit command instead of
copy-pasting logic:

```sh
work kit build-inline <name> <lang> <file>   # build one inline block
work kit promote     <name> <lang> <file>    # promote it to a kit command
work kit build       <id>                    # build a kit's work-src blocks
work kit run         <id> <task> [args…]     # run the promoted task
```

This keeps the logic DRY — one home, reused across workbooks via the kit, rather
than duplicated source blocks.

## No-native rule

If a dependency cannot become a WASM command, **file an issue — do not fake it**
and never fall back to OS bash. Agents have only bash + CLIs on PATH; the
compiler lane is how native capability enters the WASM-only world.
