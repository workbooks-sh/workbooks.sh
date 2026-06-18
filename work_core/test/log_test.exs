defmodule WorkCore.LogTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias WorkCore.Log

  test "ansi mode paints with the palette and glyphs; no-color is plain" do
    Log.configure(color: true, json: false)
    out = capture_io(fn -> Log.ok("done", detail: "12 units") end)
    assert out =~ "✓"
    assert out =~ "\e[38;2;127;214;160m"  # sage ok green
    assert out =~ "done"

    Log.configure(color: false, json: false)
    plain = capture_io(fn -> Log.ok("done") end)
    assert plain == "✓ done\n"
    refute plain =~ "\e["
  end

  test "json mode emits one structured record per event (the agent surface)" do
    Log.configure(color: false, json: true)
    out = capture_io(fn -> Log.ok("12 units", detail: "ok") end)
    assert {:ok, %{"event" => "ok", "msg" => "12 units", "detail" => "ok"}} = Jason.decode(out)
  end
end
