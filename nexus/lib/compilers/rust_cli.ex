defmodule Nexus.Compilers.RustCli do
  @moduledoc """
  Vendor a real-world Rust CLI to wasm32-wasip1 by REPURPOSING its networking at the build layer —
  no per-CLI source forks. The "shim the shared crates once, inject via the compiler" lane (Layer 1).

  A modern networked Rust CLI (gws, …) can't target wasm: `reqwest → hyper → tokio-net → mio` assumes
  sockets, and `tokio = ["full"]` is rejected on wasm. Rather than fork each CLI, we transform its
  *build manifest* (never its code) before `cargo build`:

    1. **`[patch.crates-io]` → the shims** — redirect `reqwest` to `compilers/rust/shims/reqwest`, whose
       transport is washy's `host_http` import (TLS + egress happen host-side, so `ring`/`rustls`/sockets
       drop out entirely). Written once; every reqwest CLI reuses it.
    2. **tokio feature-trim** — rewrite `tokio = ["full"]` (and any net/fs/process/signal features) to the
       wasm-supported set, so tokio compiles as a pure task executor (the shim's futures are sync-backed).

  The transforms are pure (`patch_section/2`, `trim_tokio/1`) so they're unit-tested without cargo;
  `prepare/2` applies them across a copy of the CLI tree and `build/2` runs the wasm cross-compile with
  the bundled wasi-sdk wired in (for any residual C deps).
  """

  # tokio features that compile on wasm32-wasip1 (no sockets/threads/fs/process/signal).
  @tokio_wasm_features ~w(rt macros sync io-util time)

  @doc "Absolute path to the vendored guest-side shim crates."
  def shims_dir(root \\ Nexus.Compilers.Shared.default_root()) do
    Path.expand(Path.join(root, "rust/shims"))
  end

  @doc """
  Append a `[patch.crates-io]` table to a workspace Cargo.toml redirecting each crate to a shim path.
  `crates` is a list of `{crate_name, abs_path}`. If a `[patch.crates-io]` table already exists the new
  entries are appended under it; otherwise a fresh table is added. Pure — returns the new TOML string.
  """
  def patch_section(cargo_toml, crates) when is_binary(cargo_toml) and is_list(crates) do
    lines = Enum.map(crates, fn {name, path} -> ~s(#{name} = { path = "#{path}" }) end)

    if String.contains?(cargo_toml, "[patch.crates-io]") do
      String.replace(
        cargo_toml,
        "[patch.crates-io]",
        "[patch.crates-io]\n" <> Enum.join(lines, "\n"),
        global: false
      )
    else
      String.trim_trailing(cargo_toml) <>
        "\n\n# injected by Nexus.Compilers.RustCli — host-brokered networking shims (no per-CLI fork)\n" <>
        "[patch.crates-io]\n" <> Enum.join(lines, "\n") <> "\n"
    end
  end

  @doc """
  Trim every inline `tokio = { … features = [ … ] }` declaration to the wasm-supported feature set
  (`#{inspect(@tokio_wasm_features)}`), dropping `full`/`net`/`fs`/`process`/`signal`/`rt-multi-thread`.
  Pure. Handles the common inline-table form; section form (`[dependencies.tokio]`) is left untouched.
  """
  def trim_tokio(cargo_toml) when is_binary(cargo_toml) do
    Regex.replace(
      ~r/(\btokio\b\s*=\s*\{[^}]*\bfeatures\s*=\s*)\[[^\]]*\]/,
      cargo_toml,
      fn _whole, prefix ->
        prefix <> "[" <> Enum.map_join(@tokio_wasm_features, ", ", &~s("#{&1}")) <> "]"
      end
    )
  end

  @doc "The wasm-supported tokio feature allowlist."
  def tokio_wasm_features, do: @tokio_wasm_features

  @doc """
  Rewrite a bare `#[tokio::main]` / `#[tokio::main()]` to the `current_thread` flavor. wasm32-wasip1 has
  no threads, so the default multi-thread runtime can't compile; the shim's futures are synchronous and
  ready-on-poll, so current_thread is semantically equivalent here. The ONE entry-attribute adaptation
  (not a logic fork) needed to run multi-thread-assuming async CLIs single-threaded in wasm. Pure.
  """
  def rewrite_tokio_main(rs) when is_binary(rs) do
    Regex.replace(~r/#\[tokio::main\s*\(\s*\)\s*\]|#\[tokio::main\]/, rs, ~s|#[tokio::main(flavor = "current_thread")]|)
  end

  @doc """
  Apply both transforms to a COPY of the CLI workspace at `dest` (non-destructive — `src` is untouched).
  Patches the workspace-root Cargo.toml and trims tokio in every Cargo.toml in the tree. Returns
  `{:ok, dest}`.
  """
  def prepare(src, dest, opts \\ []) do
    File.rm_rf!(dest)
    File.mkdir_p!(Path.dirname(dest))
    File.cp_r!(src, dest)

    crates = Keyword.get(opts, :patch, [{"reqwest", Path.join(shims_dir(), "reqwest")}])

    # Trim tokio everywhere; patch only the workspace root (where [patch] is honoured).
    dest
    |> Path.join("**/Cargo.toml")
    |> Path.wildcard()
    |> Enum.each(fn p -> File.write!(p, trim_tokio(File.read!(p))) end)

    # Adapt the async entrypoint to the threadless target (bare #[tokio::main] → current_thread).
    dest
    |> Path.join("**/*.rs")
    |> Path.wildcard()
    |> Enum.each(fn p -> File.write!(p, rewrite_tokio_main(File.read!(p))) end)

    root_toml = Path.join(dest, "Cargo.toml")
    if File.exists?(root_toml), do: File.write!(root_toml, patch_section(File.read!(root_toml), crates))

    {:ok, dest}
  end

  @doc """
  Cross-compile a prepared CLI workspace to wasm32-wasip1. `package` is the cargo package to build.
  Wires the bundled wasi-sdk for any residual C deps (e.g. `ring`). Returns `{:ok, wasm_path}` or
  `{:error, reason}`. Requires host `cargo` + the `wasm32-wasip1` target.
  """
  def build(dir, package, opts \\ []) do
    sdk = Keyword.get(opts, :wasi_sdk, default_wasi_sdk())

    env =
      if sdk do
        [
          {"CC_wasm32_wasip1", Path.join(sdk, "bin/clang")},
          {"AR_wasm32_wasip1", Path.join(sdk, "bin/ar")},
          {"CFLAGS_wasm32_wasip1", "--sysroot=#{Path.join(sdk, "share/wasi-sysroot")}"}
        ]
      else
        []
      end

    args = ["build", "--target", "wasm32-wasip1", "--release", "-p", package]

    case System.cmd("cargo", args, cd: dir, env: env, stderr_to_stdout: true) do
      {_out, 0} ->
        wasm = Path.join(dir, "target/wasm32-wasip1/release/#{package}.wasm")
        if File.exists?(wasm), do: {:ok, wasm}, else: {:error, :no_artifact}

      {out, code} ->
        {:error, {:cargo_failed, code, out}}
    end
  end

  defp default_wasi_sdk(root \\ Nexus.Compilers.Shared.default_root()) do
    candidates =
      [
        Path.join(root, "rust/mrustc-root"),
        Path.join(root, "rust")
      ]
      |> Enum.flat_map(fn d -> Path.wildcard(Path.join(d, "wasi-sdk-*")) end)

    Enum.find(candidates, &File.dir?/1)
  end
end
