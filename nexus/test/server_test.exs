defmodule Nexus.ServerTest do
  use ExUnit.Case, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "srv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.work"), "# Shop\n\nresource Item do\n  name :text\n  price :int\nend\n\nshow Item\n")

    mod =
      dir |> Path.join("a.work") |> File.read!() |> Nexus.Literate.parse()
      |> Enum.find(&(&1.type == :code)) |> Nexus.Resource.compile()

    Nexus.Store.clear(mod)
    Nexus.Store.create(mod, %{name: "Soup", price: 99})

    port = 4300 + System.unique_integer([:positive]) |> rem(500)
    {:ok, pid} = Nexus.Server.start_link(root: dir, port: port)
    :inets.start()
    on_exit(fn -> Process.exit(pid, :kill); File.rm_rf!(dir) end)
    {:ok, port: port}
  end

  defp get(port, path) do
    {:ok, {{_, status, _}, _h, body}} = :httpc.request(~c"http://127.0.0.1:#{port}#{path}")
    {status, to_string(body)}
  end

  test "GET / serves the SSR'd workbook with live data", %{port: port} do
    {200, html} = get(port, "/")
    assert html =~ ~s(<table class="data" data-resource="Item">)
    assert html =~ "Soup" and html =~ "99"
  end

  test "GET /data/:resource serves the rows as JSON (the server data backend)", %{port: port} do
    {200, json} = get(port, "/data/Item")
    assert {:ok, [%{"name" => "Soup", "price" => 99}]} = Jason.decode(json)
  end

  test "GET /data of an unknown resource is an empty array, not an error", %{port: port} do
    {200, json} = get(port, "/data/Ghost")
    assert json == "[]"
  end
end
