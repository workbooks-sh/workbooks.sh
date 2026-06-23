defmodule Nexus.Shell do
  @moduledoc """
  **washy** — our own featured shell, compiled to ONE wasm command module and run in the in-house wasm
  lane (clang.wasm → wasm32-wasip1 → AOT `.cwasm` → wasmtime, per-invocation). This is "bash in WASM":
  the agent's shell with NO wasmer, NO WASIX, NO fork. A real shell needs fork/exec only for pipes
  between processes — washy does pipes by BUFFERED CHAINING inside one module (`grep(cat(x))`), so it
  runs as a single dense, AOT-precompiled command. Tools are builtins compiled in; files are read/written
  over the agent's `/work` (mounted into the module). Featured, not real-bash — enough grammar for an
  agent's batch work (pipes `|`, `;`/`&&`/`||`, redirects `>`/`>>`, quoting, a coreutils-ish builtin set).

  Source: `priv/shell/sh.c`. Compiled once + cached (rebuilds when the source changes).

      {out, ok?} = Nexus.Shell.run("cat /work/a.txt | grep foo | wc -l", host_dir)
  """

  @doc "Whether the in-house shell can build (the C wasm lane is present)."
  def available? do
    File.dir?(Nexus.Compilers.Shared.default_root()) and File.exists?(src())
  end

  @doc """
  Run a shell command `line` over `host_dir` (mounted at `/work`). Returns `{output, ok?}`. The line is
  fed to the shell as stdin (the agent's bash line); the shell reads its inputs from files in `/work`.
  """
  def run(line, host_dir, _opts \\ []) when is_binary(line) and is_binary(host_dir) do
    case wasm() do
      nil ->
        {"shell: unavailable (wasm C lane not built)", false}

      w ->
        case Nexus.Sandbox.run_command(w, line, host_dir) do
          {:ok, out} -> {out, true}
          {:error, {:command_failed, _code, out}} -> {out, false}
          {:error, {:command_timeout, secs}} -> {"shell: killed (>#{secs}s)", false}
          {:error, e} -> {"shell: #{inspect(e)}", false}
        end
    end
  end

  @doc "The compiled shell wasm path (built + cached on first use; nil if the lane is unavailable)."
  def wasm do
    cache = Path.join(System.tmp_dir!(), "wb_washy.wasm")
    src = src()

    cond do
      fresh?(cache, src) -> cache
      not available?() -> nil
      true -> build(cache)
    end
  rescue
    _ -> nil
  end

  # Cache is valid when it exists and is newer than the source (rebuild on a source edit).
  defp fresh?(cache, src) do
    File.exists?(cache) and File.exists?(src) and File.stat!(cache).mtime >= File.stat!(src).mtime
  end

  defp build(cache) do
    case Nexus.Compilers.C.compile_to_wasm(src(), shape: :command) do
      {:ok, wasm} -> File.cp!(wasm, cache); cache
      _ -> nil
    end
  end

  defp src, do: Path.join(:code.priv_dir(:nexus), "shell/sh.c")
end
