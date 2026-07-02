defmodule Nexus.ServerDeeplinkTest do
  # Deep links through the REAL serve path (Bandit + Plug + Auth) on a single-workbook nexus:
  # a path matching a DECLARED `app` page pattern serves the shell with that page visible;
  # anything else stays a 404 (fail-closed — no open-ended shell serving). Security posture:
  # the request path must never reflect into the HTML, and the render cache must stay bounded
  # by the page table (keyed by matched PATTERN, not by attacker-varied concrete URLs).
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "dls_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "index.work"),
      "app do\n  title \"Shop\"\n  section \"Main\" do\n    page \"/orders\", \"orders\"\n    page \"/orders/:id\", \"detail\"\n  end\nend\n"
    )

    File.write!(Path.join(dir, "orders.work"), "# Orders\n\nall your orders\n")
    File.write!(Path.join(dir, "detail.work"), "# Order detail\n\none order in depth\n")

    port = 4300 + System.unique_integer([:positive]) |> rem(500)
    {:ok, pid} = Nexus.Server.start_link(root: dir, port: port)
    :inets.start()
    on_exit(fn -> Process.exit(pid, :kill); File.rm_rf!(dir) end)
    {:ok, port: port, dir: dir}
  end

  defp get(port, path) do
    {:ok, {{_, status, _}, _h, body}} = :httpc.request(~c"http://127.0.0.1:#{port}#{path}")
    {status, to_string(body)}
  end

  test "a deep link to a declared page serves the shell with that page visible", %{port: port} do
    {200, html} = get(port, "/orders")
    assert html =~ ~s(data-route="/orders">)
    assert html =~ ~s(data-route="/orders/:id" hidden>)
  end

  test "a :param deep link serves the matched pattern's page visible", %{port: port} do
    {200, html} = get(port, "/orders/42")
    assert html =~ ~s(data-route="/orders/:id">)
    assert html =~ ~s(data-route="/orders" hidden>)
  end

  test "an undeclared path is a 404, not an app shell (fail-closed)", %{port: port} do
    assert {404, _} = get(port, "/nope")
    assert {404, _} = get(port, "/orders/42/extra")
  end

  test "a hostile path never reflects into the served HTML", %{port: port} do
    # A payload containing an encoded slash (%2F) decodes to extra segments → no pattern → 404
    # (fail-closed). A slash-FREE payload matches "/orders/:id" and serves — that matching lane
    # must not echo the raw or decoded path anywhere in the shell.
    assert {404, _} = get(port, "/orders/%3Cscript%3Ealert(1)%3C%2Fscript%3E")

    {200, html} = get(port, "/orders/%3Cimg%20src=x%20onerror=alert(1)%3E")
    refute html =~ "<img src=x onerror=alert(1)>"
    refute html =~ "%3Cimg"
    refute html =~ "onerror"
  end

  test "param variants share ONE cache entry per pattern (bounded by the page table)", %{port: port, dir: dir} do
    {200, _} = get(port, "/orders/1")
    {200, _} = get(port, "/orders/2")
    {200, _} = get(port, "/orders/3")
    # the cache table is global to the BEAM (other suites' servers write it too) — scope to OUR root.
    entries = :ets.tab2list(:nexus_server_cache)
    patterns = for {{root, _multi, pat}, _mtime, _html} <- entries, root == dir, do: pat
    # every /orders/<id> collapses to the "/orders/:id" pattern — exactly one entry for it.
    assert Enum.count(patterns, &(&1 == "/orders/:id")) == 1
  end
end
