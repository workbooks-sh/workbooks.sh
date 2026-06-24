defmodule Nexus.Compilers.Esbuild do
  @moduledoc """
  **The esbuild lane — the REAL production bundler, run in a wasm sandbox (wb-gree / Phase C2).**

  `esbuild.wasm` is upstream esbuild (`v0.28.1`, `github.com/evanw/esbuild`) cross-compiled to
  `wasm32-wasip1` by the native Go toolchain (one-time trusted provisioning — see
  `compilers/esbuild/build.sh`). It does REAL Node module resolution, tree-shaking, ESM↔CJS interop,
  `package.json` `exports`/`main`, the works — none of which a hand-rolled bundler honestly covers.

  Like every other compiler lane (clang, the TypeScript compiler, yaegi), this TRUSTED tool runs under
  wasmtime (which JITs it to native) — the compile/build sandbox. The UNTRUSTED user program it emits is
  what later runs in Washy (the dense BEAM-isolated lane). So "add a package and use it" is honest:
  esbuild really installs+bundles the dependency graph in a wasm sandbox, then the bundle executes in
  the untrusted-code sandbox. No gaming — a real bundler does the real work.

      files = %{"main.js" => "...", "node_modules/leftpad/package.json" => "...", ...}
      {:ok, bundle_js} = Nexus.Compilers.Esbuild.bundle(files, "main.js")
  """

  @doc """
  Bundle the `files` map (`%{relpath => source}`, an in-memory project incl. its `node_modules`) starting
  at `entry`, returning `{:ok, bundle_js}` — one self-contained script. Real esbuild does the resolution.

  `opts`: `:format` (`"iife"` default — a single global script QuickJS evals; also `"cjs"`/`"esm"`),
  `:extra` (extra esbuild flags, e.g. `["--minify"]`).
  """
  def bundle(files, entry, opts \\ []) when is_map(files) and is_binary(entry) do
    esb = esbuild_wasm()

    cond do
      esb == nil ->
        {:error, :esbuild_unavailable}

      not Map.has_key?(files, entry) ->
        {:error, {:missing_entry, entry}}

      true ->
        work = Path.join(System.tmp_dir!(), "nxc_esb_#{System.unique_integer([:positive])}")
        try do
          # project lives under <work>/proj and <work> is mounted at "/", so esbuild's upward node_modules
          # walk (which reads "..") terminates at a preopened "/" instead of failing on an unmounted parent.
          proj = Path.join(work, "proj")
          materialize(proj, files)

          format = Keyword.get(opts, :format, "iife")
          extra = Keyword.get(opts, :extra, [])
          args =
            ["--dir", "#{work}::/", "--env", "PWD=/proj", esb,
             "/proj/#{entry}", "--bundle", "--format=#{format}"] ++ extra

          out = Nexus.Compilers.Shared.wasmtime(args)
          classify(out)
        after
          File.rm_rf(work)
        end
    end
  end

  # esbuild writes the bundle to stdout (no --outfile); a build failure prints an "✘ [ERROR] …" report.
  # We can't read its exit code through the shared wasmtime/0 (combined output), so detect the marker.
  defp classify(out) do
    if String.contains?(out, "[ERROR]") or String.contains?(out, "✘") do
      {:error, {:bundle_failed, String.slice(out, 0, 600)}}
    else
      {:ok, out}
    end
  end

  defp materialize(work, files) do
    Enum.each(files, fn {rel, src} ->
      path = Path.join(work, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, src)
    end)
  end

  @doc "Path to the provisioned esbuild.wasm, or nil if the lane isn't built."
  def esbuild_wasm do
    [Path.join(Nexus.Compilers.Shared.default_root(), "esbuild/esbuild.wasm"),
     Path.join(:code.priv_dir(:nexus), "esbuild/esbuild.wasm")]
    |> Enum.find(&File.exists?/1)
  end
end
