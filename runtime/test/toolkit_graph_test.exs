defmodule Workbooks.ToolkitGraphTest do
  @moduledoc """
  The toolkit→toolkit dependency graph (Phase 0, WORKPONENTS-AGENT-INTEGRATION).

  `#+REQUIRES` carries two distinct kinds of entry:
    * a TOOLKIT-ID edge — a token naming a known `:toolkit:` id (optionally
      `id@semver`); this is a real graph edge and pulls the dependency's
      skills/index into a subscriber's closure.
    * a native-CLI pre-flight — a token with a version operator (`git>=2.30`) or a
      bare non-toolkit name; this is NOT a graph edge (preserves the shipped
      manifests, which name native CLIs).

  Asserts: (a) a toolkit-id REQUIRES resolves transitively into an agent's index,
  (b) a native-CLI REQUIRES creates no edge, (c) a cycle errors.
  """
  use ExUnit.Case, async: false

  alias Workbooks.Toolkits

  setup_all do
    case Workbooks.OQL.start_link(nil) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end

  # Build a scratch toolkit root we fully control. `tks` is a list of
  # {id, requires_line | nil} — each becomes <root>/<id>/manifest.org with a
  # skills/overview.org so injection_text has a skill to list.
  defp scratch_root(tks) do
    base = Path.join(System.tmp_dir!(), "wb_graph_#{:erlang.unique_integer([:positive])}")
    root = Path.join(base, "root")

    for {id, requires} <- tks do
      dir = Path.join(root, id)
      File.mkdir_p!(Path.join(dir, "skills"))
      req_line = if requires, do: "#+REQUIRES: #{requires}\n", else: ""

      File.write!(Path.join(dir, "manifest.org"), """
      #+TITLE: #{id} toolkit
      #+STATUS: stable
      #+TAGLINE: tagline for #{id}
      #{req_line}
      * #{id} — scratch                                            :toolkit:
        :PROPERTIES:
        :ID:        #{id}
        :STATUS:    stable
        :SKILL_DIR: skills/
      #{if requires, do: "  :REQUIRES:  #{requires}\n", else: ""}  :END:
      """)

      File.write!(Path.join([dir, "skills", "overview.org"]), """
      #+TITLE: #{id} overview
      #+CAPTION: #{id} cap
      the #{id} skill body
      """)
    end

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(base) end)
    root
  end

  describe "closure_disk/2 — transitive closure over toolkit-id edges" do
    test "(a) a toolkit-id REQUIRES pulls the dependency into the closure + the agent index" do
      # ui REQUIRES icons (a known toolkit id) → toolkit-id edge.
      # icons REQUIRES glyphs → transitive.
      root =
        scratch_root([
          {"ui", "icons"},
          {"icons", "glyphs"},
          {"glyphs", nil}
        ])

      # Declaring only "ui" must close over icons + glyphs.
      closed = Toolkits.closure_disk(["ui"], root)
      assert "ui" in closed
      assert "icons" in closed
      assert "glyphs" in closed
      # dependency appears before its dependent (declared-first / dep-after order).
      assert Enum.find_index(closed, &(&1 == "glyphs")) <
               Enum.find_index(closed, &(&1 == "ui"))

      # The prompt index that an agent declaring only :TOOLKITS: ui receives names
      # all three (this is the "subscribe to A, get B's skills" behavior).
      idx = Toolkits.injection_text(["ui"], root)
      assert idx =~ "ui"
      assert idx =~ "icons"
      assert idx =~ "glyphs"
      assert idx =~ "tagline for glyphs"
    end

    test "(b) a native-CLI REQUIRES creates NO graph edge" do
      # `git>=2.30` is a version-pinned native CLI, and `node>=20` / `cargo` are
      # native too — none is a known toolkit id here, none is followed.
      root =
        scratch_root([
          {"forge", "git>=2.30 node>=20 cargo"}
        ])

      closed = Toolkits.closure_disk(["forge"], root)
      assert closed == ["forge"]

      idx = Toolkits.injection_text(["forge"], root)
      assert idx =~ "forge"
      refute idx =~ "git>=2.30"
      refute idx =~ "node"
    end

    test "(b2) a bare token matching a native CLI name is only an edge if a toolkit by that id exists" do
      # `git` with no version is a :dep candidate, but no `git` toolkit is installed
      # in this scratch root → it falls back to a pre-flight, no edge, no crash.
      root = scratch_root([{"forge", "git"}])
      assert Toolkits.closure_disk(["forge"], root) == ["forge"]
    end

    test "(c) a dependency cycle errors (the REQUIRES graph is a DAG)" do
      root =
        scratch_root([
          {"a", "b"},
          {"b", "c"},
          {"c", "a"}
        ])

      assert_raise ArgumentError, ~r/cycle/, fn ->
        Toolkits.closure_disk(["a"], root)
      end
    end

    test "closure dedups a diamond (B and C both REQUIRE D)" do
      root =
        scratch_root([
          {"a", "b c"},
          {"b", "d"},
          {"c", "d"},
          {"d", nil}
        ])

      closed = Toolkits.closure_disk(["a"], root)
      assert Enum.count(closed, &(&1 == "d")) == 1
      assert Enum.sort(closed) == ["a", "b", "c", "d"]
    end
  end

  describe "parse_descriptor/1 — #+REQUIRES typing" do
    test "version-operator tokens are :cli; bare/@semver names are :dep candidates" do
      d =
        Toolkits.parse_descriptor("""
        #+TITLE: x
        #+REQUIRES: git>=2.30, glyphs, icons@0.2.0 cargo (build only)
        """)

      # version-pinned → always a native CLI pre-flight, never an edge
      assert {:cli, "git>=2.30"} in d.requires
      # bare / @semver → :dep CANDIDATE (becomes an edge only if it matches a known
      # toolkit id at closure time; `cargo` here will fall back to a pre-flight).
      assert {:dep, "cargo", "cargo"} in d.requires
      assert {:dep, "glyphs", "glyphs"} in d.requires
      assert {:dep, "icons", "icons@0.2.0"} in d.requires
      # parenthetical prose is dropped
      refute Enum.any?(d.requires, fn t -> match?({_, "build"}, t) or match?({_, "build", _}, t) end)
    end

    test "no #+REQUIRES → empty requires (no crash)" do
      assert Toolkits.parse_descriptor("#+TITLE: x\n").requires == []
    end
  end

  describe "the shipped manifests stay edge-free (no regression)" do
    @root Path.expand("../../toolkits", __DIR__)

    test "every shipped #+REQUIRES classifies as native CLI (zero toolkit-id edges)" do
      # The 10 manifests with #+REQUIRES name native CLIs (git>=2.30, node>=20,
      # cargo, xcode, wb, …) — none must become a graph edge against the real id
      # set, or the closure would silently widen a long-stable agent's index.
      known =
        Path.wildcard(Path.join(@root, "*/manifest.org"))
        |> Enum.map(&(Path.dirname(&1) |> Path.basename()))

      for manifest <- Path.wildcard(Path.join(@root, "*/manifest.org")) do
        d = Toolkits.parse_descriptor(File.read!(manifest))

        for t <- d.requires do
          case t do
            {:dep, name, _} ->
              refute name in known,
                     "#{manifest}: REQUIRES token #{inspect(name)} unexpectedly matches a toolkit id"

            {:cli, _} ->
              :ok
          end
        end
      end
    end
  end
end
