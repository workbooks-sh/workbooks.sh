# Density benchmark (wb-s61c) — turn "a billion things on 1GB" into a NUMBER.
#
# Spins up N stateful Cells (each owns a live wasmer bash process over /work), then measures:
#   * spawn latency  — wall-clock to start a cell to a ready, command-serving state
#   * memory/cell    — RSS of the wasmer OS processes / N
#   * cells-per-GB   — extrapolated from memory/cell
#
# Run:  N=20 mix run bench/density.exs        (locally — a first read; run on a Fly machine for prod truth)
#
# This is a HONEST first measurement, not the headline. The headline claim only earns its place once this
# runs on a real deploy target and is published next to a container baseline.

n = String.to_integer(System.get_env("N") || "20")
IO.puts("== density bench: N=#{n} stateful cells ==")

unless Nexus.Wasmer.available?() do
  IO.puts("wasmer absent — cannot measure. Install wasmer + retry.")
  System.halt(0)
end

# ── spawn N cells, timing each ──────────────────────────────────────────────────────────────────────
{total_us, cells} =
  :timer.tc(fn ->
    Enum.map(1..n, fn _ ->
      {us, {:ok, cell}} = :timer.tc(fn -> Nexus.Cell.start(grant: ["fs", "exec"], stateful: true) end)
      {cell, us}
    end)
  end)

spawn_us = Enum.map(cells, fn {_c, us} -> us end)
avg_spawn = Enum.sum(spawn_us) / n
p50 = spawn_us |> Enum.sort() |> Enum.at(div(n, 2))

# prove they actually work (one real command each is overkill; sample a few)
ok =
  cells |> Enum.take(3)
  |> Enum.all?(fn {c, _} -> Nexus.Cell.run(c, "echo ok") |> String.trim() == "ok" end)

# ── measure memory: sum RSS (KB) of the wasmer OS processes ──────────────────────────────────────────
# Each stateful cell holds one `wasmer run bash` subprocess. Count them + their RSS.
{ps_out, _} = System.cmd("/bin/sh", ["-c", "ps -axo rss=,comm= | grep -i wasmer | grep -v grep || true"])
rss_kb =
  ps_out
  |> String.split("\n", trim: true)
  |> Enum.map(fn line -> line |> String.trim() |> String.split(~r/\s+/) |> hd() |> Integer.parse() end)
  |> Enum.flat_map(fn {kb, _} -> [kb]; _ -> [] end)

wasmer_procs = length(rss_kb)
total_rss_mb = Enum.sum(rss_kb) / 1024
per_cell_mb = if wasmer_procs > 0, do: total_rss_mb / wasmer_procs, else: 0.0
cells_per_gb = if per_cell_mb > 0, do: round(1024 / per_cell_mb), else: 0

IO.puts("""

  cells started        #{n}   (sample commands ok? #{ok})
  wasmer processes     #{wasmer_procs}
  spawn avg / p50      #{Float.round(avg_spawn / 1000, 1)} ms / #{Float.round(p50 / 1000, 1)} ms
  total spawn          #{Float.round(total_us / 1000, 1)} ms
  total wasmer RSS     #{Float.round(total_rss_mb, 1)} MB
  memory / cell        #{Float.round(per_cell_mb, 2)} MB
  >> CELLS PER GB      ~#{cells_per_gb}   (RSS-extrapolated; BEAM process overhead is ~KB, negligible)

  caveat: local read. wasmer caches compiled modules across processes, so per-cell RSS on a warm host is
  optimistic vs a cold Fly machine. Re-run on the deploy target for the publishable number.
""")

Enum.each(cells, fn {c, _} -> Nexus.Cell.stop(c) end)
