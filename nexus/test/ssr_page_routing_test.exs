defmodule Nexus.SSRPageRoutingTest do
  # An `app` block routes multi-page sites by EXPLICIT URL path — `page "/orders", "orders"`
  # (path -> .work file), with the legacy `page "orders"` still supported (filename as route).
  # The render is PURE MECHANISM: `[data-route]` containers + a router, ZERO chrome/skin/nav of ours.
  use ExUnit.Case, async: false

  defp site(files) do
    dir = Path.join(System.tmp_dir!(), "pr_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Enum.each(files, fn {name, body} -> File.write!(Path.join(dir, name), body) end)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "explicit `page \"/path\" \"file\"` routes articles + nav by URL path, content from the file" do
    dir =
      site(%{
        "index.work" =>
          "app do\n  title \"Shop\"\n  section \"Main\" do\n    page \"/orders\", \"orders\"\n    page \"/about\", \"about\"\n  end\nend\n",
        "orders.work" => "# Orders\n\nyour orders here\n",
        "about.work" => "# About\n\nabout us\n"
      })

    html = Nexus.SSR.render(dir)

    assert html =~ ~s(data-route="/orders")
    assert html =~ ~s(data-route="/about")
    assert html =~ "Orders"
    assert html =~ "about us"
    # the standard imposes NO chrome/skin/class of ours — no baked shell, nav, or stylesheet.
    refute html =~ "wb-side"
    refute html =~ "wb-nav"
    refute html =~ "wb-brand"
    refute html =~ "wb-page"
    refute html =~ ".wb-main"
  end

  test "legacy `page \"key\"` still works, normalised to a leading-slash path" do
    dir =
      site(%{
        "index.work" => "app do\n  title \"X\"\n  section \"S\" do\n    page \"home\"\n  end\nend\n",
        "home.work" => "# Home\n\nwelcome\n"
      })

    html = Nexus.SSR.render(dir)
    assert html =~ ~s(data-route="/home")
    assert html =~ "welcome"
  end
end
