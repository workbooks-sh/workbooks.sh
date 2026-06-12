# Deny-path e2e (no connection attempted -> works offline). Proves the override fires for: SSRF floor,
# and the scoped allow-list (a public host NOT on the list is blocked before any connect).
run = fn allow, url ->
  wasi = %Wasmex.Wasi.WasiP2Options{allow_http: true, net_allow: allow}
  {:ok, pid} = Wasmex.Components.start_link(%{path: "/tmp/net_probe.component.wasm", wasi: wasi})
  case Wasmex.Components.call_function(pid, "probe", [url], 8000) do
    {:ok, s} -> if String.starts_with?(s, "BLOCKED"), do: "BLOCKED", else: "REACHED("<>String.slice(s,0,20)<>")"
    {:error, e} -> "ERR " <> (inspect(e) |> String.slice(0,40))
    o -> inspect(o) |> String.slice(0,40)
  end
end
# SSRF floor (no list): internal must be blocked
IO.puts("SSRF metadata (no list)        => " <> run.(nil, "http://169.254.169.254/"))
# Allow-list DENY: public host 8.8.8.8 NOT in [example.com] -> blocked by list (no connect)
IO.puts("ALLOWLIST 8.8.8.8 vs [example] => " <> run.(["example.com"], "http://8.8.8.8/"))
# Allow-list + SSRF together: 127.0.0.1 with a list -> blocked by SSRF floor
IO.puts("SSRF 127.0.0.1 (with list)     => " <> run.(["example.com"], "http://127.0.0.1/"))
