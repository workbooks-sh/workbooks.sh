# Per-cell concurrent footprint: one shared module (decode once) + N parked cells each holding
# their packed linear memory + counter atomics. Measures cells/GB.
measure = fn pages, n ->
  parent = self()
  :erlang.garbage_collect()
  before = :erlang.memory(:total)
  pids = for _ <- 1..n do
    spawn(fn ->
      mem = :atomics.new(max(1,pages)*8192, signed: false)   # packed linear memory (8 bytes/slot)
      f = :atomics.new(1, signed: true); d = :atomics.new(1, signed: true); p = :atomics.new(1, signed: false)
      :atomics.put(mem, 1, 1)  # touch so it's resident
      send(parent, :ready)
      receive do :stop -> {mem,f,d,p} end
    end)
  end
  for _ <- 1..n, do: (receive do :ready -> :ok end)
  :erlang.garbage_collect()
  delta = :erlang.memory(:total) - before
  per = delta / n
  Enum.each(pids, &send(&1, :stop))
  IO.puts("#{pages}-page cells: N=#{n}  total=#{Float.round(delta/1_048_576,1)}MB  per-cell=#{Float.round(per/1024,1)}KB  => #{round(1_073_741_824/per)} cells/GB")
end
measure.(1, 3000)
measure.(2, 3000)
