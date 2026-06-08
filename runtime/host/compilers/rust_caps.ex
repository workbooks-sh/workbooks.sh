defmodule Workbooks.Compilers.RustCaps do
  @moduledoc """
  The honest contract for Rust-in-WASM compilation (wb-0sz). Two jobs:

    * `capabilities/0` — the machine-readable matrix of what the in-sandbox Rust lane does and does
      NOT support, each limitation tagged with a mitigation and whether the BEAM can offload it.
    * `diagnose/1` — turn a raw `rust_compile_to_wasm` error into `%{category, summary, mitigation}`
      so an agent or a person gets ACTIONABLE feedback instead of a wasm trap.

  Why this exists: the runtime compiles real Rust to wasm with mrustc (no native rustc), which has
  hard edges (a ~1.74 language ceiling, no build-script execution, a bounded version resolver). When
  someone asks for something past an edge, they should learn *what* edge and *what to do*, not stare
  at `{:rustc_failed, "<wasm trap>"}`. The matrix is the same set of facts in declarative form, for
  docs/skills and for agents to read before they try.
  """

  @doc """
  The capability/limitation matrix. Each limitation: what's unsupported, the mitigation a caller can
  apply today, and `:beam_offload` — whether the BEAM host could (or already does) lift it by doing
  what wasm can't (the "offshore it safely" lever).
  """
  def capabilities do
    %{
      # What reliably works — pure-Rust crates compile + run entirely in the sandbox.
      supported: [
        "leaf + multi-file pure-Rust crates (mod resolution, hyphenated names)",
        "declarative macros (macro_rules!) — bitflags, lazy_static, cfg-if, …",
        "transitive dependency trees (sparse-index resolution + version fallback)",
        "feature-gated optional deps via explicit dep_features (cargo-style activation)",
        "proc-macro derives — EXECUTED in-sandbox (serde et al.), auto-routed through the BEAM",
        "data-table crates (unicode-width, regex-syntax), error crates (anyhow), once_cell, log",
        "full std (alloc/collections/fmt/io over a wasi shim); i128 (emulated)"
      ],

      # What is NOT supported, why, and how to get unblocked.
      limitations: [
        %{
          id: :language_ceiling,
          what: "Rust newer than the mrustc ceiling (~1.74): edition 2024, some GATs, newest syntax.",
          mitigation: "Pin an OLDER crate version whose source predates the construct (e.g. syn 1.x, serde_derive ≤ 1.0.156). Newest releases of big crates often need syn 2.0 / edition 2024.",
          beam_offload: false,
          note: "Fundamental to mrustc; not BEAM-offloadable. Raising it means a newer mrustc (wb-1ec)."
        },
        %{
          id: :no_build_script,
          what: "Crates whose build.rs does CODE GENERATION (include!(env!(\"OUT_DIR\"))), bindgen, or compiles bundled C. (autocfg-style build.rs is fine — it's skipped and the cfgs have fallbacks.)",
          mitigation: "Pin a version that doesn't generate code, or vendor the generated file. Pure-Rust + autocfg crates work.",
          beam_offload: true,
          note: "Offloadable: the BEAM can compile+run the build script in-sandbox and pre-open OUT_DIR (wb-iht). Same lever as proc-macro execution."
        },
        %{
          id: :version_resolution,
          what: "The resolver tries the exact pin + the 6 newest in-range versions only. If the only compilable version is older than that window, a bare `dep` fails.",
          mitigation: "PIN a known-good version explicitly: `regex@1.5.4`, not `regex`. The newest release frequently exceeds the ceiling.",
          beam_offload: false,
          note: "Could widen the window / add ceiling-aware ordering (wb-rxi)."
        },
        %{
          id: :proc_macro_reexport,
          what: "Re-exported derive macros: `use serde::Serialize; #[derive(Serialize)]` fails (serde re-exports serde_derive's derive).",
          mitigation: "Import the derive DIRECTLY from its *_derive crate: `use serde_derive::{Serialize, Deserialize};`. Then enable the parent's derive feature so it's pulled.",
          beam_offload: false,
          note: "mrustc doesn't resolve re-exported proc-macro derives (resolve/index.cpp TODO). Tracked: wb-5bv."
        },
        %{
          id: :no_threads,
          what: "No OS threads and limited atomics (wasm32, single-threaded; no 64-bit atomics). std::thread, rayon, and thread-based parts of tokio won't work.",
          mitigation: "Write single-threaded code. For concurrency, model it on the host (BEAM) side, not inside the wasm.",
          beam_offload: :partial,
          note: "The BEAM can mediate an async executor / fan-out, but not transparently run threaded crates."
        },
        %{
          id: :no_raw_io,
          what: "No raw sockets / filesystem / clock-driven IO at runtime. std::net, std::fs, and real network calls don't reach the OS.",
          mitigation: "Use the Dock host capabilities (browse-fetch, llm-complete, vfs-query) — Policy-gated host functions the BEAM implements — instead of raw syscalls.",
          beam_offload: true,
          note: "This IS the offload model. Dock exists for typed components; wiring it to compiled-Rust core wasm is wb-1mv (declare extern imports + run under Wasmex with allow_undefined)."
        }
      ],

      # Limitations the BEAM already lifts by doing what wasm can't (the proven offload lever).
      beam_lifts: [
        "proc-macro EXECUTION — runs the proc-macro server wasm host-side (Workbooks.ProcMacroHost); the user compile is auto-routed through Wasmex when a dep is a proc-macro crate.",
        "network / LLM / VFS — Dock host functions (host/instance/imports.ex), Policy-gated; a program only gets the caps the Policy grants (fails to instantiate otherwise)."
      ]
    }
  end

  @doc """
  Classify a `rust_compile_to_wasm` / PackageManager error into actionable guidance.
  Returns %{category, summary, mitigation, raw}. Pattern-matches the error atom and (for compile
  failures) the mrustc message inside it. Always returns something — falls back to :unknown.
  """
  def diagnose(error) do
    raw = inspect(error) |> String.slice(0, 400)
    text = stringify(error)

    cond do
      match?({:error, {:no_matching_version, _, _}}, error) or String.contains?(text, "no_matching_version") ->
        hit(:version_resolution, "No version in the requested range matched.",
          "Pin a specific known-good version (e.g. `crate@1.2.3`).", raw)

      # All in-range candidates failed to compile → almost always the ceiling on newer releases.
      String.contains?(text, "dep_compile_failed") ->
        hit(:language_ceiling, "Every tried version of a dependency failed to compile — typically the mrustc ~1.74 ceiling on newer releases.",
          "Pin an OLDER version of the crate (and of proc-macro deps: syn 1.x, serde_derive ≤ 1.0.156).", raw)

      String.contains?(text, "Missing handlers for") ->
        hit(:proc_macro_reexport, "A `#[derive(...)]` couldn't resolve to its proc-macro handler.",
          "Import the derive directly from its *_derive crate (`use serde_derive::Serialize;`), not via a re-export (`use serde::Serialize;`).", raw)

      String.contains?(text, "Unexpected token") or String.contains?(text, "TOK_RWORD") or String.contains?(text, "Unknown crate type") ->
        hit(:language_ceiling, "mrustc rejected the source syntax — it's newer than the ~1.74 ceiling, or a wrong edition.",
          "Pin an older crate version, or check the crate's edition (2024 is unsupported).", raw)

      String.contains?(text, "OUT_DIR") or String.contains?(text, "build script") or String.contains?(text, "no_build_script") ->
        hit(:no_build_script, "The crate relies on a build script that generates code — not executed in-sandbox.",
          "Pin a version that doesn't generate code, or vendor the generated file. (Build-script execution is a planned BEAM offload, wb-iht.)", raw)

      String.contains?(text, "Unable to locate crate") or String.contains?(text, "Unable to open crate") ->
        hit(:version_resolution, "A dependency crate couldn't be located/opened.",
          "Check the dep name/version; pin an explicit version. If it's a proc-macro re-export, import the derive from its *_derive crate.", raw)

      String.contains?(text, "link_failed") or String.contains?(text, "undefined symbol") ->
        hit(:no_raw_io, "Link failed on an undefined symbol — often raw IO/net the sandbox doesn't provide.",
          "Use Dock host capabilities (browse-fetch/llm/vfs) instead of std::net/std::fs; threads aren't available.", raw)

      true ->
        hit(:unknown, "Compilation failed for a reason not yet classified.",
          "See `Workbooks.Compilers.RustCaps.capabilities/0` for supported/unsupported classes; the raw error is attached.", raw)
    end
  end

  defp hit(category, summary, mitigation, raw),
    do: %{category: category, summary: summary, mitigation: mitigation, raw: raw}

  defp stringify(error) do
    s = inspect(error, limit: :infinity, printable_limit: :infinity)
    # mrustc stderr is often nested+escaped inside the tuple; decode escapes so the patterns hit.
    case Code.string_to_quoted(s) do
      _ -> String.replace(s, "\\n", "\n")
    end
  end
end
