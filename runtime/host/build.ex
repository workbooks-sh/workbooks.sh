defmodule Workbooks.Build do
  @moduledoc """
  The tangle build step — source components → WASM — as part of pack/unpack.

  A workbook RUNS WebAssembly, not source. So packing a buildable workbook has a
  compile stage: each component's source (a Rust crate, a standalone `.rs`, …) is
  built to a `.wasm`, and it's the `.wasm` that ships in the runnable artifact.
  The build INPUTS (source, `target/`, `Cargo.lock`) are scaffolding — they
  belong on the SOURCE rail (GitHub) and in an archive, but NOT in the runnable
  HTML. That's the "build files don't make it into the HTML unless they're
  WebAssembly" rule, made concrete: three projections of the same workbook —

    * runnable  → the `.wasm` outputs (what executes, in the Dock / WASM sandbox)
    * source    → the source inputs (what a human reads + diffs on GitHub)
    * archive   → both

  REAL, not stubbed: uses the toolchains actually present (`cargo component` for
  crates, `rustc --target wasm32-*` for a lone `.rs`). A component whose toolchain
  is missing (e.g. JS needs `jco`) is returned UNBUILT with the reason — never
  faked (honest TODO at the boundary). Same builder runs locally and in a cloud
  engine; the output `.wasm` is what the Wasmex Instance loads either way.
  """

  @wasm_magic <<0x00, 0x61, 0x73, 0x6D>>

  @doc """
  Build every buildable component found under `dir`. Returns
  %{built: [%{name, rel, bytes}], unbuilt: [%{name, reason}]}. `bytes` is the
  compiled `.wasm` (validated by magic number). Best-effort + honest: a missing
  toolchain yields an `unbuilt` entry, not a fake artifact.
  """
  def build(dir, opts \\ []) do
    results = dir |> discover() |> Enum.map(&build_one(&1, dir, opts))

    %{
      built: for({:built, b} <- results, do: b),
      unbuilt: for({:unbuilt, u} <- results, do: u)
    }
  end

  @doc "Is this path a build INPUT (source/scaffold that compiles away — keep off the runnable artifact)?"
  def build_input?(path) do
    base = Path.basename(path)
    String.contains?(path, ["target/", "node_modules/", ".cargo/"]) or
      base in ~w(Cargo.toml Cargo.lock package.json) or
      Path.extname(path) in ~w(.rs)
  end

  @doc "Is this path a build OUTPUT (a .wasm — ships to the runnable workbook)?"
  def build_output?(path), do: Path.extname(path) == ".wasm"

  # ── discover ────────────────────────────────────────────────────────────────
  # A component is a Rust crate (a dir with Cargo.toml) OR a standalone .rs file.
  defp discover(dir) do
    crates = (dir |> Path.join("**/Cargo.toml") |> Path.wildcard()) |> Enum.map(&{:crate, Path.dirname(&1)})

    crate_dirs = MapSet.new(crates, fn {:crate, d} -> d end)

    loose =
      dir
      |> Path.join("**/*.rs")
      |> Path.wildcard()
      |> Enum.reject(fn f -> Enum.any?(crate_dirs, &String.starts_with?(f, &1)) end)
      |> Enum.map(&{:rs, &1})

    # JS/Svelte/TS components compile via jco — detected so the gap is HONEST
    # (reported unbuilt with a reason), never silently skipped.
    js =
      dir
      |> Path.join("**/*.{js,ts,svelte}")
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, "node_modules/"))
      |> Enum.map(&{:js, &1})

    crates ++ loose ++ js
  end

  defp build_one({:js, src}, root, _opts) do
    name = Path.relative_to(src, root)
    reason = if has?("jco"), do: "jco present but JS component build not wired yet", else: "jco not installed"
    {:unbuilt, %{name: name, reason: reason}}
  end

  # ── build one ────────────────────────────────────────────────────────────────
  defp build_one({:crate, crate_dir}, root, opts) do
    name = Path.relative_to(crate_dir, root)

    if has?("cargo-component") do
      case sh(["cargo", "component", "build", "--release"], crate_dir, opts) do
        {:ok, _} ->
          case Path.wildcard(Path.join(crate_dir, "target/wasm32-*/release/*.wasm")) |> List.first() do
            nil -> {:unbuilt, %{name: name, reason: "cargo component built but no .wasm found"}}
            wasm -> emit(name, wasm)
          end

        {:error, out} -> {:unbuilt, %{name: name, reason: "cargo component failed: #{snippet(out)}"}}
      end
    else
      {:unbuilt, %{name: name, reason: "cargo-component not installed"}}
    end
  end

  defp build_one({:rs, src}, root, opts) do
    name = Path.relative_to(src, root)

    if has?("rustc") do
      out = src <> ".wasm"

      case sh(["rustc", "--target", "wasm32-unknown-unknown", "--crate-type", "cdylib", "-O", src, "-o", out], Path.dirname(src), opts) do
        {:ok, _} -> emit(name, out)
        {:error, o} -> {:unbuilt, %{name: name, reason: "rustc failed: #{snippet(o)}"}}
      end
    else
      {:unbuilt, %{name: name, reason: "rustc not installed"}}
    end
  end

  defp emit(name, wasm_path) do
    bytes = File.read!(wasm_path)

    case bytes do
      <<@wasm_magic, _::binary>> -> {:built, %{name: name, rel: Path.basename(wasm_path), bytes: bytes}}
      _ -> {:unbuilt, %{name: name, reason: "output is not valid wasm (bad magic)"}}
    end
  end

  # ── shell ─────────────────────────────────────────────────────────────────────
  defp sh([cmd | args], cwd, opts) do
    {out, code} = System.cmd(cmd, args, cd: cwd, stderr_to_stdout: true, env: opts[:env] || [])
    if code == 0, do: {:ok, out}, else: {:error, out}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp has?(bin), do: match?({_, 0}, System.cmd("sh", ["-c", "command -v #{bin}"], stderr_to_stdout: true))
  defp snippet(out), do: out |> String.split("\n", trim: true) |> Enum.take(-2) |> Enum.join(" ")
end
