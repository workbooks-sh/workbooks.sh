defmodule Nexus.SSRBlockMdTest do
  # Regression: an INDENTED bullet/quote used to send `group_blocks/2` into an infinite loop (the
  # paragraph split returns empty, so it recurses on the same list forever), hanging `SSR.render` /
  # `work weave` (measured >45s). The progress guard must render these fast and keep their content.
  use ExUnit.Case, async: false

  defp wb(body) do
    dir = Path.join(System.tmp_dir!(), "bm_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "index.work"), body)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp render_bounded(dir, ms \\ 5_000) do
    task = Task.async(fn -> Nexus.SSR.render(dir) end)

    case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, html} -> html
      _ -> flunk("SSR.render did not terminate within #{ms}ms (group_blocks infinite-loop regression)")
    end
  end

  test "an indented bullet renders (no infinite loop) and keeps its content" do
    html = render_bounded(wb("# T\n\nintro\n  - indented one\n  - indented two\n\nafter\n"))
    assert html =~ "indented one"
    assert html =~ "after"
  end

  test "an indented blockquote renders (no infinite loop)" do
    html = render_bounded(wb("# T\n\nintro\n  > indented quote\n\nafter\n"))
    assert html =~ "indented quote"
    assert html =~ "after"
  end

  test "numbered list followed by an indented bullet (the real trigger) terminates" do
    body = "# T\n\n3. **Snapshot** — verified\n   detail line\n   - LEARNED: a nested note\n     continuation\n\ndone\n"
    html = render_bounded(wb(body))
    assert html =~ "LEARNED"
    assert html =~ "done"
  end
end
