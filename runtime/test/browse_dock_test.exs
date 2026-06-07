defmodule Workbooks.BrowseDockTest do
  @moduledoc """
  P6 — proves the `browse-fetch` Dock import is wired end to end to
  `Workbooks.Browse` (Route B: the host owns network egress; the component never
  opens a socket — no wasi:http/sockets granted).

  The closure test drives the real `Imports.for_caps` browse closure straight
  into Workbooks.Browse against a localhost fixture HTTP server. The component
  test instantiates the prebuilt `engine-browse-probe` WASM (which hard-imports
  `browse-fetch`) under the `network` profile and calls `run(url)` — the Dock
  call reaches Browse, fetches the localhost page, extracts it, and returns the
  JSON page through the typed import.
  """
  use ExUnit.Case, async: false

  alias Workbooks.Instance.Imports

  @html """
  <!DOCTYPE html>
  <html><head><title>Dock Fixture Page</title>
  <meta name="description" content="proof the dock reaches browse">
  </head><body><h1>Hello Dock</h1><p>browse-fetch round-trip.</p></body></html>
  """

  setup do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    server =
      spawn_link(fn -> serve(listen) end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listen)
    end)

    %{url: "http://127.0.0.1:#{port}/"}
  end

  # A one-shot HTTP/1.1 server: accept, drain the request, reply with @html.
  defp serve(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        _ = :gen_tcp.recv(sock, 0, 2_000)
        body = @html

        resp =
          "HTTP/1.1 200 OK\r\n" <>
            "Content-Type: text/html; charset=utf-8\r\n" <>
            "Content-Length: #{byte_size(body)}\r\n" <>
            "Connection: close\r\n\r\n" <> body

        :gen_tcp.send(sock, resp)
        :gen_tcp.close(sock)
        serve(listen)

      {:error, _} ->
        :ok
    end
  end

  test "policy: browse cap is granted by network/posix, denied by minimal" do
    assert "browse" in Workbooks.Policy.caps(:network)
    assert "browse" in Workbooks.Policy.caps(:posix)
    refute "browse" in Workbooks.Policy.caps(:minimal)
  end

  test "the browse Dock closure reaches Workbooks.Browse and returns the extracted page", %{url: url} do
    info = %{id: "b1", tenant: "dev", profile: :network}
    imports = Imports.for_caps(Workbooks.Policy.caps(:network), nil, info, [])

    {:fn, browse_fetch} = Map.fetch!(imports, "browse-fetch")

    out = browse_fetch.(url)
    page = Jason.decode!(out)

    assert page["url"] == url
    assert page["title"] == "Dock Fixture Page"
    assert page["description"] == "proof the dock reaches browse"
    assert page["text"] =~ "browse-fetch round-trip"
  end

  test "the engine-browse-probe component fetches a URL through the Dock end to end", %{url: url} do
    bytes = File.read!("build/fixtures/engine-browse-probe.wasm")
    id = "browse-probe-#{System.unique_integer([:positive])}"

    {:ok, _} = Workbooks.Instance.Supervisor.start_instance(id, bytes, policy: :network)

    {:ok, ran} = Workbooks.Instance.call(id, "run", [url])
    page = Jason.decode!(ran)

    # The component never opened a socket — it called browse-fetch, the host
    # (Workbooks.Browse) fetched the localhost fixture, extracted it, and the
    # JSON page came back through the typed Dock import.
    assert page["url"] == url
    assert page["title"] == "Dock Fixture Page"
    assert page["text"] =~ "browse-fetch round-trip"
  end

  test "a minimal-profile Instance cannot instantiate the browse component (cap enforced)" do
    bytes = File.read!("build/fixtures/engine-browse-probe.wasm")
    id = "browse-deny-#{System.unique_integer([:positive])}"

    # minimal does not grant `browse`, so the host omits browse-fetch and the
    # component (which hard-imports it) fails to link — enforcement by construction.
    assert {:error, _} = Workbooks.Instance.Supervisor.start_instance(id, bytes, policy: :minimal)
  end
end
