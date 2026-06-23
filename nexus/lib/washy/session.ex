defmodule Nexus.Washy.Session do
  @moduledoc """
  A **stateful shell session** on Washy — the long-lived counterpart to a fresh per-command run. The
  washy shell is stateless per invocation (each command is a fresh wasm instance), so the session
  carries the cross-command state — **cwd and environment variables** — here in Elixir and threads it
  into each run: it injects the current env as leading assignments, and rewrites `cd`/`pwd`/`export`
  against the tracked state. File writes already persist (the shared `/work` dir), so a workflow like
  `cd build && export X=1` then `make` / `echo $X` works across separate `run/2` calls.

  This replaces `Nexus.Wasmer.Session` (the wasmer subprocess that kept its state by staying alive) on
  the dense BEAM lane. A GenServer so it can be linked to a `Cell` and reaped with it.
  """
  use GenServer

  @doc "Start a session over `host_dir` (mounted at /work). Linked to the caller."
  def start_link(host_dir, opts \\ []) when is_binary(host_dir),
    do: GenServer.start_link(__MODULE__, {host_dir, opts}, opts)

  @doc "Run `line` in the session; returns `{output, exit_code}`. cwd/env persist to the next call."
  def run(server, line, _opts \\ []) when is_binary(line), do: GenServer.call(server, {:run, line}, 130_000)

  def stop(server), do: GenServer.stop(server, :normal)

  @impl true
  def init({dir, _opts}), do: {:ok, %{dir: dir, cwd: "/work", env: %{}}}

  @impl true
  def handle_call({:run, line}, _from, st) do
    {st2, effective} = rewrite(st, line)
    {out, ok?} = Nexus.Shell.run(effective, st2.dir)
    {:reply, {out, if(ok?, do: 0, else: 1)}, st2}
  end

  # ── line rewriting: capture cd/export, transform cd/pwd/export, inject persisted env ─────────────
  defp rewrite(st, line) do
    # split keeping the &&/||/; separators so command structure (short-circuits) is preserved
    parts = Regex.split(~r/(\s*(?:&&|\|\||;)\s*)/, line, include_captures: true)

    {st2, rebuilt} =
      parts
      |> Enum.with_index()
      |> Enum.reduce({st, []}, fn {part, i}, {acc, out} ->
        # even indices are commands, odd indices are separators (kept verbatim)
        if rem(i, 2) == 1 do
          {acc, [part | out]}
        else
          {acc2, transformed} = command(acc, String.trim(part))
          {acc2, [transformed | out]}
        end
      end)

    env_preamble = Enum.map_join(st2.env, "", fn {k, v} -> "#{k}=#{v}; " end)
    {st2, env_preamble <> (rebuilt |> Enum.reverse() |> Enum.join())}
  end

  defp command(st, cmd) do
    cond do
      # `cd DIR` — track cwd here; the washy shell has no cwd, so it becomes a no-op (`true`)
      match = Regex.run(~r/^cd\s+(\S+)$/, cmd) ->
        [_, dir] = match
        {%{st | cwd: resolve(st.cwd, dir)}, "true"}

      # `pwd` — answer from the tracked cwd
      cmd == "pwd" ->
        {st, "echo #{st.cwd}"}

      # `export VAR=val` — persist + emit a plain assignment for this run
      match = Regex.run(~r/^export\s+([A-Za-z_][A-Za-z0-9_]*)=(.*)$/, cmd) ->
        [_, k, v] = match
        {%{st | env: Map.put(st.env, k, v)}, "#{k}=#{v}"}

      # a bare leading assignment `VAR=val` — persist it too (session-scoped), keep as-is
      match = Regex.run(~r/^([A-Za-z_][A-Za-z0-9_]*)=(\S*)$/, cmd) ->
        [_, k, v] = match
        {%{st | env: Map.put(st.env, k, v)}, cmd}

      true ->
        {st, cmd}
    end
  end

  # resolve a cd target against the current cwd (absolute, relative, and `..`)
  defp resolve(_cwd, "/" <> _ = abs), do: normalize(abs)
  defp resolve(cwd, rel), do: normalize(cwd <> "/" <> rel)

  defp normalize(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.reduce([], fn
      "..", [_ | rest] -> rest
      "..", [] -> []
      ".", acc -> acc
      seg, acc -> [seg | acc]
    end)
    |> Enum.reverse()
    |> then(&("/" <> Enum.join(&1, "/")))
  end
end
