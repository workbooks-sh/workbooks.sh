# mono

`mono` is the debut of the `#+EXEC: kernel` shape: a `bytes → bytes` reactor compiled from C in-sandbox (via `clang.wasm`) and looped by the fabric — instantiated once, called per frame. It takes RGBA pixels and returns same-length RGBA with each pixel replaced by its luminance (integer average); trailing non-quad bytes pass through unchanged.

## When to reach for it

Reach for `mono` as the reference for what a kernel-shape toolkit *is*: a hot loop the runtime opens once and drives at high frequency, rather than a CLI you shell out to per call. Use it to grayscale RGBA buffers, or as the worked example when authoring your own kernel.

## Example

```
wb toolkit build mono            # clang.wasm compiles the C source → KernelRegistry
# then loop it from the engine:
Workbooks.Fabric.map_kernel(:mono, frames)
# or one-shot:  POST /rcp/kernel/run
```

## What it grants

- A `bytes → bytes` kernel ABI: `process(in_len) → out_len`, with `in_ptr()`/`out_ptr()` locating the shared arena.
- RGBA → grayscale (integer-average luminance) in a tight per-frame loop.
- The canonical example of the `#+EXEC: kernel` build path (C source → `Compilers.c_compile_to_kernel`).

## Maturity

Experimental — the first deployed kernel-shape toolkit, intended as much as a pattern proof as a feature.
