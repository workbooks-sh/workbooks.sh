defmodule Workbooks.BrowseHeadlessTest do
  @moduledoc """
  Pins the headless browse capability (JS-rendered page load via local Chrome
  --dump-dom). SSRF floor + arg + exec-gating are deterministic (no Chrome / no
  network); the actual render is proven live.
  """
  use ExUnit.Case, async: true
  alias Workbooks.Browse.Headless
  alias Workbooks.Agent

  test "SSRF floor blocks internal/metadata URLs BEFORE launching the browser" do
    assert Headless.render("http://169.254.169.254/latest/meta-data/") == {:error, :blocked}
    assert Headless.render("http://127.0.0.1:4000/") == {:error, :blocked}
    assert Headless.render("http://10.0.0.1/") == {:error, :blocked}
  end

  test "missing/empty url → :no_url" do
    assert Headless.render("") == {:error, :no_url}
    assert Headless.render(nil) == {:error, :no_url}
  end

  test "browse tool is exec-gated (no host process spawn without exec)" do
    {out, _} = Agent.__exec_one_for_test__(%{name: "browse", args: %{"url" => "https://example.com"}}, %{tenant: "t"})
    assert out =~ "not permitted"
  end

  test "browse tool WITH exec still enforces the SSRF floor" do
    {out, _} = Agent.__exec_one_for_test__(%{name: "browse", args: %{"url" => "http://192.168.0.1/"}}, %{exec: true, tenant: "t"})
    assert out =~ "blocked"
  end
end
