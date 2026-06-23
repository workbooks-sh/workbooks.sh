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

  Executed on **Washy** — the shell wasm runs IN-PROCESS on the pure-Elixir interpreter, BEAM-isolated
  and bounded (fuel + wall-clock + memory), in a fresh Task so a runaway command can't harm the host.
  No wasmtime subprocess, no fork: this is the dense lane (thousands of cells/GB). `host_dir` is bridged
  to Washy's virtual FS (load in, flush writes back); the prod path uses the tenant-scoped SQLite VFS.
  """
  @timeout_ms 30_000
  def run(line, host_dir, opts \\ []) when is_binary(line) and is_binary(host_dir) do
    case wasm() do
      nil -> {"shell: unavailable (wasm C lane not built)", false}
      w -> run_washy(w, line, host_dir, opts)
    end
  end

  defp run_washy(wasm_path, line, host_dir, opts) do
    {:ok, mod} = Nexus.Washy.decode_cached(File.read!(wasm_path))
    vfs0 = load_dir(host_dir)
    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)

    progs = programs()

    task =
      Task.async(fn ->
        Process.put(:washy_backend, :map)
        Process.put(:washy_vfs, vfs0)
        Process.put(:washy_stdin, line)
        Process.put(:washy_argv, ["sh"])
        Process.put(:washy_fds, %{})
        Process.put(:washy_nextfd, 4)
        Process.put(:washy_programs, progs)

        {code, out} =
          try do
            {_r, o} = Nexus.Washy.call_io(mod, "_start", [], opts)
            {0, o}
          catch
            :throw, {:washy_exit, c} ->
              {c, Process.get(:washy_out, []) |> Enum.reverse() |> IO.iodata_to_binary()}
          end

        {code, out, Process.get(:washy_vfs, vfs0)}
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {code, out, vfs}} -> flush_dir(host_dir, vfs, vfs0); {out, code == 0}
      {:ok, other} -> {"shell: #{inspect(other)}", false}
      {:exit, reason} -> {"shell: crashed (#{inspect(reason)})", false}
      nil -> {"shell: killed (>#{timeout}ms)", false}
    end
  end

  # The program registry host_exec resolves against: coreutils as the multicall `:default`, so any
  # non-builtin command the shell hits (seq, printf, cut, basename, …) runs the real tool. Memoized
  # (decode once, share) — the 9.6MB coreutils module isn't re-read/re-decoded per shell invocation.
  defp programs do
    case :persistent_term.get({__MODULE__, :programs}, nil) do
      nil ->
        progs =
          case coreutils_path() do
            nil -> %{}
            path -> {:ok, m} = Nexus.Washy.decode_cached(File.read!(path)); %{default: m}
          end

        :persistent_term.put({__MODULE__, :programs}, progs)
        progs

      progs ->
        progs
    end
  end

  defp coreutils_path do
    ["kits/coreutils.wasm", Path.join(:code.priv_dir(:nexus), "kits/coreutils.wasm")]
    |> Enum.find(&File.exists?/1)
  end

  # ── host_dir ↔ Washy virtual FS bridge (local/desktop; prod uses the tenant SQLite VFS) ──────────
  defp load_dir(host_dir) do
    if File.dir?(host_dir) do
      Path.wildcard(Path.join(host_dir, "**"))
      |> Enum.filter(&File.regular?/1)
      |> Map.new(fn p -> {Path.relative_to(p, host_dir), File.read!(p)} end)
    else
      %{}
    end
  end

  # write back files that are new or changed (the shell's redirects/creates); leaves untouched files alone
  defp flush_dir(host_dir, vfs, vfs0) do
    Enum.each(vfs, fn {rel, bytes} ->
      if Map.get(vfs0, rel) != bytes do
        path = Path.join(host_dir, rel)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, bytes)
      end
    end)
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
