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
    results = dir |> discover() |> Enum.flat_map(&build_one(&1, dir, opts))

    %{
      built: for({:built, b} <- results, do: b),
      unbuilt: for({:unbuilt, u} <- results, do: u)
    }
  end

  @doc """
  Is this path a build INPUT (source/scaffold that compiles away — keep off the
  runnable artifact)? Covers Rust + the JS/UI frameworks (Svelte/Astro/Solid/
  Preact, etc — their source + node_modules + manifests), since a workbook ships
  compiled output, not source.
  """
  def build_input?(path) do
    base = Path.basename(path)
    String.contains?(path, ["target/", "node_modules/", ".cargo/", "/src/"]) or
      base in ~w(Cargo.toml Cargo.lock package.json package-lock.json bun.lockb pnpm-lock.yaml tsconfig.json vite.config.js svelte.config.js astro.config.mjs) or
      Path.extname(path) in ~w(.rs .jsx .tsx .ts .svelte .astro .vue)
  end

  @doc "Is this path a build OUTPUT (ships to the runnable workbook — .wasm for compute, or a built bundle under dist/build/.output)?"
  def build_output?(path) do
    Path.extname(path) == ".wasm" or String.contains?(path, ["/dist/", "/build/", "/.output/"])
  end

  # ── discover ────────────────────────────────────────────────────────────────
  # A component is a Rust crate (Cargo.toml), a standalone .rs, OR a JS/UI project
  # (a package.json with a `build` script — Svelte/Astro/Solid/Preact/… all look
  # the same here: a project that builds itself). Each returns a LIST of results
  # since one project yields many output files.
  defp discover(dir) do
    crates = (dir |> Path.join("**/Cargo.toml") |> Path.wildcard()) |> Enum.map(&{:crate, Path.dirname(&1)})
    crate_dirs = MapSet.new(crates, fn {:crate, d} -> d end)

    js_projects =
      dir
      |> Path.join("**/package.json")
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, "node_modules/"))
      |> Enum.filter(&has_build_script?/1)
      |> Enum.map(&{:js_project, Path.dirname(&1)})

    loose_rs =
      dir
      |> Path.join("**/*.rs")
      |> Path.wildcard()
      |> Enum.reject(fn f -> Enum.any?(crate_dirs, &String.starts_with?(f, &1)) end)
      |> Enum.map(&{:rs, &1})

    crates ++ loose_rs ++ js_projects
  end

  defp has_build_script?(pkg_json) do
    case Jason.decode(File.read!(pkg_json)) do
      {:ok, %{"scripts" => %{"build" => _}}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # ── build one (→ list of results) ────────────────────────────────────────────
  defp build_one({:crate, crate_dir}, root, opts) do
    name = Path.relative_to(crate_dir, root)

    if has?("cargo-component") do
      case sh(["cargo", "component", "build", "--release"], crate_dir, opts) do
        {:ok, _} ->
          case Path.wildcard(Path.join(crate_dir, "target/wasm32-*/release/*.wasm")) |> List.first() do
            nil -> [{:unbuilt, %{name: name, reason: "cargo component built but no .wasm found"}}]
            wasm -> [emit_wasm(name, wasm)]
          end

        {:error, out} -> [{:unbuilt, %{name: name, reason: "cargo component failed: #{snippet(out)}"}}]
      end
    else
      [{:unbuilt, %{name: name, reason: "cargo-component not installed"}}]
    end
  end

  defp build_one({:rs, src}, root, opts) do
    name = Path.relative_to(src, root)

    if has?("rustc") do
      out = src <> ".wasm"

      case sh(["rustc", "--target", "wasm32-unknown-unknown", "--crate-type", "cdylib", "-O", src, "-o", out], Path.dirname(src), opts) do
        {:ok, _} -> [emit_wasm(name, out)]
        {:error, o} -> [{:unbuilt, %{name: name, reason: "rustc failed: #{snippet(o)}"}}]
      end
    else
      [{:unbuilt, %{name: name, reason: "rustc not installed"}}]
    end
  end

  # A JS/UI project builds ITSELF (its package.json carries the framework + the
  # build script), so we don't special-case Svelte vs Astro vs Solid — we run the
  # project's own toolchain (bun, falling back to npm) and collect its output
  # bundle. The compiled JS/CSS is the OUTPUT (embeds in the workbook view); the
  # source + node_modules are inputs that don't ship to the runnable form.
  defp build_one({:js_project, dir}, root, opts) do
    name = Path.relative_to(dir, root)
    pm = cond do has?("bun") -> "bun"; has?("npm") -> "npm"; true -> nil end

    cond do
      is_nil(pm) ->
        [{:unbuilt, %{name: name, reason: "no JS package manager (bun/npm) installed"}}]

      true ->
        with {:ok, _} <- sh([pm, "install"], dir, opts),
             {:ok, _} <- sh(build_cmd(pm), dir, opts) do
          case js_outputs(dir, root) do
            [] -> [{:unbuilt, %{name: name, reason: "build ran but produced no dist/build/.output"}}]
            outs -> outs
          end
        else
          {:error, o} -> [{:unbuilt, %{name: name, reason: "#{pm} build failed: #{snippet(o)}"}}]
        end
    end
  end

  defp build_cmd("bun"), do: ["bun", "run", "build"]
  defp build_cmd("npm"), do: ["npm", "run", "build"]

  defp js_outputs(dir, root) do
    ~w(dist build .output)
    |> Enum.flat_map(fn out -> dir |> Path.join(out) |> Path.join("**/*") |> Path.wildcard() end)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(fn f -> {:built, %{name: Path.relative_to(f, root), rel: Path.basename(f), bytes: File.read!(f)}} end)
  end

  defp emit_wasm(name, wasm_path) do
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
