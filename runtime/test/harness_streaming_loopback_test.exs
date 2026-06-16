defmodule Workbooks.HarnessStreamingLoopbackTest do
  @moduledoc """
  STREAMING child_process OVER THE LOOPBACK HTTP protocol (wb-b9xv.11) — the exact hop the SM-lane
  `child_process.spawn()` drives. Proves the wire protocol the harness consumes:

      POST /__wb/spawn  {name, argv}      -> {handle}              (token-gated, broker spine)
      POST /__wb/stream/<handle>          -> chunk + x-wb-done/exit (long-poll incremental drain)
      POST /__wb/stdin/<handle> {data}    -> {ok}                  (live stdin write)

  And the streaming kill-switch: `ExecLoopback.revoke(token)` KILLS every in-flight child spawned under that
  token (a revoked/ended session's streams die mid-flight). Same token-gate + principal-gate + default-deny
  spine as /__wb/exec. `:pallet` — needs the prebuilt coreutils.wasm.
  """
  use ExUnit.Case, async: false

  alias Workbooks.{ExecLoopback, CommandRegistry, Pallet}

  setup_all do
    System.put_env("WB_HARNESS", "1")
    {:ok, _} = Task.start(fn -> ExecLoopback.start_listener(); Process.sleep(:infinity) end)
    wait_for_loopback()
    System.delete_env("WB_HARNESS")
    ready? = Pallet.seed_one("coreutils") == :ok and "coreutils" in CommandRegistry.list()
    {:ok, ready?: ready?}
  end

  defp wait_for_loopback(tries \\ 100) do
    cond do
      tries <= 0 -> :ok
      match?(p when is_integer(p), :persistent_term.get({ExecLoopback, :port}, nil)) -> :ok
      true -> Process.sleep(10); wait_for_loopback(tries - 1)
    end
  end

  defp base, do: "http://127.0.0.1:#{ExecLoopback.port()}"

  defp skip_unless(ready?) do
    if not ready?, do: IO.puts("\n[skip] coreutils not seeded")
    ready?
  end

  @tag :pallet
  @tag timeout: 120_000
  test "full HTTP streaming protocol: spawn -> incremental stream -> exit, plus live stdin", %{ready?: ready?} do
    if skip_unless(ready?) do
      tok = mint_exec_token("loop-stream-#{System.unique_integer([:positive])}")

      # SPAWN a large stream over the loopback.
      assert {:ok, %{status: 200, body: body}} =
               post(base() <> "/__wb/spawn", tok, %{name: "coreutils", argv: ["seq", "200000"]})

      assert %{"handle" => handle} = Jason.decode!(body)

      # DRAIN incrementally: long-poll /__wb/stream/<handle>; each call returns the bytes since the last poll.
      {chunks, exit_code} = drain_loop(handle, tok, [])
      nonempty = Enum.reject(chunks, &(&1 == ""))
      full = Enum.join(chunks)

      assert exit_code == 0
      assert full =~ "200000"
      # STREAMING over HTTP: the output came back across MANY /__wb/stream calls, not one terminal body.
      assert length(nonempty) >= 5, "expected incremental HTTP drains, got #{length(nonempty)}"
    end
  end

  @tag :pallet
  @tag timeout: 120_000
  test "live stdin over /__wb/stdin reaches the child (cat echoes the marker)", %{ready?: ready?} do
    if skip_unless(ready?) do
      tok = mint_exec_token("loop-stdin-#{System.unique_integer([:positive])}")

      assert {:ok, %{status: 200, body: body}} =
               post(base() <> "/__wb/spawn", tok, %{name: "coreutils", argv: ["cat"]})

      handle = Jason.decode!(body)["handle"]
      assert {:ok, %{status: 200}} = post(base() <> "/__wb/stdin/#{handle}", tok, %{data: "HELLO_OVER_LOOPBACK\n"})

      assert poll_for_marker(handle, tok, "HELLO_OVER_LOOPBACK")
    end
  end

  @tag :pallet
  @tag timeout: 120_000
  test "REVOKE(token) kills in-flight children + the stream handle is dead afterwards", %{ready?: ready?} do
    if skip_unless(ready?) do
      tok = mint_exec_token("loop-revoke-#{System.unique_integer([:positive])}")

      assert {:ok, %{status: 200, body: body}} =
               post(base() <> "/__wb/spawn", tok, %{name: "coreutils", argv: ["seq", "5000000"]})

      handle = Jason.decode!(body)["handle"]
      # one drain to confirm it's live and producing.
      assert {:ok, %{status: 200}} = post(base() <> "/__wb/stream/#{handle}", tok, %{})

      # REVOKE the token: kills every in-flight child of the token AND removes the grant.
      ExecLoopback.revoke(tok)

      # the handle's grant is gone => stream is now denied (the in-flight child was killed mid-flight).
      assert {:ok, %{status: 403}} = post(base() <> "/__wb/stream/#{handle}", tok, %{})
      # and a fresh spawn on the revoked token is denied (no grant).
      assert {:ok, %{status: 403}} = post(base() <> "/__wb/spawn", tok, %{name: "coreutils", argv: ["seq", "1"]})
    end
  end

  @tag :pallet
  @tag timeout: 120_000
  test "PRINCIPAL revoke kills the in-flight streaming child (not just on token-revoke)", %{ready?: ready?} do
    if skip_unless(ready?) do
      principal = "loop-prevoke-#{System.unique_integer([:positive])}"
      tok = mint_exec_token(principal)

      assert {:ok, %{status: 200, body: body}} =
               post(base() <> "/__wb/spawn", tok, %{name: "coreutils", argv: ["seq", "5000000"]})

      handle = Jason.decode!(body)["handle"]
      # confirm it's live and producing.
      assert {:ok, %{status: 200}} = post(base() <> "/__wb/stream/#{handle}", tok, %{})

      # PRINCIPAL-level revoke (NOT token-revoke): flips the Revocation flag AND kills every live child of the
      # principal mid-flight. The token grant itself is untouched, so this proves the principal kill-switch.
      :ok = Workbooks.Revocation.revoke(principal)
      on_exit(fn -> Workbooks.Revocation.unrevoke(principal) end)

      # the child was killed mid-stream: the handle is dead/dropped and the route denies (403) the revoked
      # principal even though the TOKEN grant still exists.
      assert {:ok, %{status: 403}} = post(base() <> "/__wb/stream/#{handle}", tok, %{})
      # a fresh spawn on the same (token, revoked-principal) is also refused at the broker spine.
      assert {:ok, %{status: 403}} = post(base() <> "/__wb/spawn", tok, %{name: "coreutils", argv: ["seq", "1"]})
    end
  end

  @tag :pallet
  @tag timeout: 120_000
  test "stdin past the cumulative cap / rate limit is refused (429) and kills the child", %{ready?: ready?} do
    if skip_unless(ready?) do
      tok = mint_exec_token("loop-stdincap-#{System.unique_integer([:positive])}")

      assert {:ok, %{status: 200, body: body}} =
               post(base() <> "/__wb/spawn", tok, %{name: "coreutils", argv: ["cat"]})

      handle = Jason.decode!(body)["handle"]

      # one chunk under the per-window rate budget succeeds.
      chunk = String.duplicate("x", 1_000_000)
      assert {:ok, %{status: 200}} = post(base() <> "/__wb/stdin/#{handle}", tok, %{data: chunk})

      # hammer stdin within one rolling window until the cumulative/rate cap rejects with 429.
      status = push_until_rejected(handle, tok, chunk, 40)
      assert status == 429, "expected a 429 stdin rejection, never got one"

      # over-cap killed the child: a subsequent stdin to the dead handle is denied (403).
      assert {:ok, %{status: 403}} = post(base() <> "/__wb/stdin/#{handle}", tok, %{data: "more"})
    end
  end

  @tag :pallet
  test "spawn keeps the broker spine: no token => denied; unknown command => denied" do
    # absent/invalid token => default-deny (no child spawns)
    assert {:ok, %{status: 403}} = post(base() <> "/__wb/spawn", "bogus-token", %{name: "coreutils", argv: ["seq", "1"]})

    tok = mint_exec_token("loop-spine-#{System.unique_integer([:positive])}")
    assert {:ok, %{status: 403}} = post(base() <> "/__wb/spawn", tok, %{name: "rm", argv: ["-rf", "/"]})
  end

  # ── helpers ──────────────────────────────────────────────────────────────────────────────────

  defp mint_exec_token(principal) do
    tok = ExecLoopback.mint(%{allow: true, commands: :all, principal: principal})
    on_exit(fn -> ExecLoopback.revoke(tok) end)
    tok
  end

  defp drain_loop(handle, tok, acc, tries \\ 2_000) do
    assert tries > 0, "stream never terminated"
    {:ok, %{status: 200, body: chunk, headers: h}} = post(base() <> "/__wb/stream/#{handle}", tok, %{})

    if header(h, "x-wb-done") == "1" do
      {Enum.reverse([chunk | acc]), String.to_integer(header(h, "x-wb-exit") || "0")}
    else
      drain_loop(handle, tok, [chunk | acc], tries - 1)
    end
  end

  # POST stdin chunks until the route rejects with 429 (cumulative cap or rate limit), or give up.
  defp push_until_rejected(_handle, _tok, _chunk, 0), do: :never
  defp push_until_rejected(handle, tok, chunk, tries) do
    case post(base() <> "/__wb/stdin/#{handle}", tok, %{data: chunk}) do
      {:ok, %{status: 429}} -> 429
      {:ok, %{status: 200}} -> push_until_rejected(handle, tok, chunk, tries - 1)
      {:ok, %{status: s}} -> s
    end
  end

  defp poll_for_marker(handle, tok, marker, tries \\ 60)
  defp poll_for_marker(_handle, _tok, _marker, 0), do: false

  defp poll_for_marker(handle, tok, marker, tries) do
    {:ok, %{status: 200, body: chunk}} = post(base() <> "/__wb/stream/#{handle}", tok, %{})
    if String.contains?(chunk, marker), do: true, else: poll_for_marker(handle, tok, marker, tries - 1)
  end

  defp header(headers, key) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(to_string(k)) == key, do: to_string(v) end)
  end

  defp post(url, token, body) do
    _ = Application.ensure_all_started(:inets)
    headers = [{~c"x-wb-exec", String.to_charlist(token)}]
    request = {String.to_charlist(url), headers, ~c"application/json", Jason.encode!(body)}

    case :httpc.request(:post, request, [{:timeout, 10_000}], body_format: :binary) do
      {:ok, {{_v, status, _r}, h, resp_body}} ->
        {:ok, %{status: status, body: resp_body, headers: h}}

      other ->
        other
    end
  end
end
