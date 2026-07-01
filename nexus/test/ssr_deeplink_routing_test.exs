defmodule Nexus.SSRDeeplinkRoutingTest do
  # P2.2: a deep-link request (`render/2` `:route`) server-renders the MATCHED page visible, with
  # `:param` segments matched by pattern (/orders/:id ⇐ /orders/42). The client router mirrors the
  # match and captures params. No route ⇒ every page starts hidden (offline weave behaviour).
  use ExUnit.Case, async: false

  defp site(files) do
    dir = Path.join(System.tmp_dir!(), "dl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Enum.each(files, fn {name, body} -> File.write!(Path.join(dir, name), body) end)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp param_site do
    site(%{
      "index.work" =>
        "app do\n  title \"Shop\"\n  section \"Main\" do\n    page \"/orders\", \"orders\"\n    page \"/orders/:id\", \"detail\"\n  end\nend\n",
      "orders.work" => "# Orders\n\nall your orders\n",
      "detail.work" => "# Order detail\n\none order in depth\n"
    })
  end

  # a page's routable container renders VISIBLE when it carries no `hidden` attr — `data-route="X">` —
  # and HIDDEN when it does — `data-route="X" hidden>`. No chrome/class of ours wraps it.
  defp visible?(html, route), do: html =~ ~s(data-route="#{route}">)
  defp hidden?(html, route), do: html =~ ~s(data-route="#{route}" hidden>)

  test "a deep link to a :param route renders the matched page visible, the rest hidden" do
    html = Nexus.SSR.render(param_site(), route: "/orders/42")

    assert visible?(html, "/orders/:id"), "the /orders/:id page should be server-rendered visible"
    assert hidden?(html, "/orders"), "the sibling /orders page should start hidden"
    # both pages' content is present in the shell either way (client can swap without a fetch).
    assert html =~ "one order in depth"
    assert html =~ "all your orders"
  end

  test "a deep link to a static route renders that page visible" do
    html = Nexus.SSR.render(param_site(), route: "/orders")

    assert visible?(html, "/orders")
    assert hidden?(html, "/orders/:id")
  end

  test "no route (offline weave) leaves every page hidden for the client to resolve" do
    html = Nexus.SSR.render(param_site())

    assert hidden?(html, "/orders")
    assert hidden?(html, "/orders/:id")
  end

  test "an unmatched route falls through to the first page (client), no page forced visible" do
    html = Nexus.SSR.render(param_site(), route: "/nope/nowhere")

    # nothing matched ⇒ nothing server-forced-visible; the client's show() first-page fallback covers it.
    assert hidden?(html, "/orders")
    assert hidden?(html, "/orders/:id")
  end

  test "the client router ships the pattern matcher + exposes captured params" do
    html = Nexus.SSR.render(param_site(), route: "/orders/42")

    assert html =~ "function match(path)"
    assert html =~ "__wb_params"
  end

  test "route_pattern/2 resolves a concrete path to its page pattern (the server cache key)" do
    dir = param_site()

    # a param URL collapses to its pattern, so every /orders/<id> shares one cached shell.
    assert Nexus.SSR.route_pattern(dir, "/orders/42") == "/orders/:id"
    assert Nexus.SSR.route_pattern(dir, "/orders/99") == "/orders/:id"
    # a static path resolves to itself; an unknown path and a non-app folder both yield nil.
    assert Nexus.SSR.route_pattern(dir, "/orders") == "/orders"
    assert Nexus.SSR.route_pattern(dir, "/nope") == nil

    plain = site(%{"index.work" => "# Plain\n\njust a doc\n"})
    assert Nexus.SSR.route_pattern(plain, "/anything") == nil
  end
end
