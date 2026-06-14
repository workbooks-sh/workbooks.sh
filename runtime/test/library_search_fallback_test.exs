defmodule Workbooks.LibrarySearchFallbackTest do
  @moduledoc """
  Pins the embeddings-down keyword fallback for the agent's recall (search_dir).
  When Workbooks.Embed is unavailable, search must degrade to substring/term
  ranking over the chunks it read — NOT silently return nothing. Deterministic
  (literal_rank seam; no embed model).
  """
  use ExUnit.Case, async: true
  alias Workbooks.Library

  defp chunk(text), do: %{path: "p.org", headline: "h", text: text}

  test "ranks chunks by query-term overlap, most hits first" do
    chunks = [chunk("nothing relevant here"), chunk("we handle auth headers in the broker"), chunk("auth only")]
    [top | _] = Library.literal_rank_for_test(chunks, "auth headers", 5)
    assert top.text =~ "auth headers"
    assert top.score >= 2
  end

  test "drops zero-hit chunks (honest: no fabricated matches)" do
    chunks = [chunk("alpha beta"), chunk("gamma delta")]
    assert Library.literal_rank_for_test(chunks, "zzz nomatch", 5) == []
  end

  test "respects k" do
    chunks = for i <- 1..10, do: chunk("auth token #{i}")
    assert length(Library.literal_rank_for_test(chunks, "auth token", 3)) == 3
  end

  test "search_dir on an empty dir returns [] (no embed call, deterministic)" do
    dir = Path.join(System.tmp_dir!(), "lsf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    assert Library.search_dir(dir, "anything") == []
  end

  test "search_dir reads real files, chunks them, and ranks the matching doc first" do
    # End-to-end recall over actual files on disk. The assertion holds for BOTH
    # ranking paths — semantic (embed cosine) and the embeddings-down literal
    # fallback both surface the doc that owns the distinctive query terms first.
    dir = Path.join(System.tmp_dir!(), "lsf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    File.write!(Path.join(dir, "broker.org"),
      "* Broker\nthe auth header brokering pipeline handles credential rotation per hop")
    File.write!(Path.join(dir, "render.org"),
      "* Render\nthe org renderer emits html headings and bullet lists from source")

    hits = Library.search_dir(dir, "auth header brokering credential rotation", k: 5)
    assert hits != []
    assert hd(hits).path == "broker.org"
    assert hd(hits).text =~ "credential rotation"
  end

  test "search_dir with no matching terms returns nothing when embeddings are down (honest recall)" do
    # Guards the no-fabrication contract on the real path: a query that overlaps
    # NO chunk term must yield [] in the literal fallback — never an invented hit.
    # (Skipped automatically if an embedder is configured, since cosine ranks all.)
    if match?({:error, _}, Workbooks.Embed.embed(["probe"])) do
      dir = Path.join(System.tmp_dir!(), "lsf-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      File.write!(Path.join(dir, "a.org"), "* A\nalpha beta gamma")
      assert Library.search_dir(dir, "zzz qqq nomatch", k: 5) == []
    end
  end
end
