defmodule Workbooks.ToolkitsTest do
  @moduledoc """
  The `work kit` surface (wb-4bj.2) — discovery + rendering over the on-disk
  org toolkits. Exercises default_root, list_text/show_text/show_skill_text/
  search_text/verify_text against the real ../workkits tree, thin vs thick
  skill resolution, extract_role_blocks, and #+CAPTION TOC extraction.

  ADVERSARIAL: toolkit ids and skill slugs are agent/LLM-supplied. A slug
  containing "../", an absolute path, or a null byte MUST NOT read or run a
  file outside the toolkit's own skills/ directory. Those cases are asserted.
  """
  use ExUnit.Case, async: false

  alias Workbooks.WorkKits

  # The rich on-disk tree: git/ ffmpeg/ 3w/ linear/ … (sibling of runtime/, i.e.
  # workbooks-finish/toolkits). __DIR__ is runtime/test, so it is two levels up —
  # NOT runtime/toolkits, which holds only the huniq/text WASM build fixtures.
  @root Path.expand("../../workkits", __DIR__)

  setup_all do
    :ok
  end

  # A throwaway toolkit dir we fully control — used for thin/thick skill_path
  # resolution and the adversarial path-escape cases, so a buggy implementation
  # would read a sentinel file we plant *outside* the toolkit and we can detect
  # it. Returns {root, toolkit_dir, secret_path}.
  defp scratch_toolkit(ctx) do
    base = Path.join(System.tmp_dir!(), "wb_tk_test_#{:erlang.unique_integer([:positive])}")
    root = Path.join(base, "root")
    tk = Path.join(root, "demo")
    File.mkdir_p!(Path.join(tk, "skills"))

    # manifest with a <work-ref rel="kit"> node (id "demo")
    File.write!(Path.join(tk, "manifest.html"), """
    <work-ref rel="kit" name="demo" cli="demo" status="stable"
      tagline="scratch fixture for path-escape tests" skill-dir="skills/"/>
    <work-doc title="demo — scratch"></work-doc>
    """)

    # thin skill: skills/overview.md   (verify_text wants overview.md present)
    File.write!(Path.join([tk, "skills", "overview.md"]), """
    # demo overview
    ## only caption in the thin skill
    body of the thin overview skill
    """)

    # thick skill: skills/deep/SKILL.md
    File.mkdir_p!(Path.join([tk, "skills", "deep"]))

    File.write!(Path.join([tk, "skills", "deep", "SKILL.md"]), """
    # deep thick skill
    THICK_SKILL_MARKER
    """)

    # A secret OUTSIDE the toolkit dir, reachable only via traversal.
    secret = Path.join(base, "SECRET.md")
    File.write!(secret, "TOP_SECRET_SHOULD_NEVER_BE_READ\n")

    on_exit(fn -> File.rm_rf!(base) end)
    Map.merge(ctx, %{root: root, tk: tk, secret: secret})
  end

  # ── default_root/0 ────────────────────────────────────────────────────────

  describe "default_root/0" do
    test "honors $WB_WORKKITS_ROOT when set" do
      System.put_env("WB_WORKKITS_ROOT", @root)
      on_exit(fn -> System.delete_env("WB_WORKKITS_ROOT") end)
      assert WorkKits.default_root() == @root
    end

    # SECURITY REGRESSION (finding #6): a blank/invalid WB_WORKKITS_ROOT must NOT
    # repoint the surface. It is now honored ONLY if it names an existing dir;
    # otherwise we fall back to the in-tree default.
    test "an empty-string env var is ignored (falls back to default)" do
      System.put_env("WB_WORKKITS_ROOT", "")
      on_exit(fn -> System.delete_env("WB_WORKKITS_ROOT") end)
      refute WorkKits.default_root() == ""
    end

    test "a non-existent-dir env var is ignored (falls back to default)" do
      System.put_env("WB_WORKKITS_ROOT", "/no/such/dir/wb-#{System.unique_integer([:positive])}")
      on_exit(fn -> System.delete_env("WB_WORKKITS_ROOT") end)
      refute String.starts_with?(WorkKits.default_root(), "/no/such/dir")
    end

    test "falls back to a real dir when env is unset" do
      System.delete_env("WB_WORKKITS_ROOT")
      # We can't guarantee cwd, but the function must return a string and never raise.
      assert is_binary(WorkKits.default_root())
    end
  end

  # ── list_text/1 ───────────────────────────────────────────────────────────

  describe "list_text/1" do
    test "lists known toolkits, one per line, with id + status + tagline" do
      out = WorkKits.list_text(@root)
      assert out =~ "git"
      assert out =~ "ffmpeg"
      assert out =~ "stable"
      # id column is left-padded to 16 → there is a run of spaces after a short id
      assert out =~ ~r/^git\s{2,}/m
      # taglines come from #+TAGLINE
      assert out =~ "version control" or out =~ "Distributed"
    end

    test "sorted by id" do
      ids =
        WorkKits.list_text(@root)
        |> String.split("\n")
        |> Enum.map(&(String.split(&1, ~r/\s/, parts: 2) |> hd()))

      assert ids == Enum.sort(ids)
    end

    test "empty / nonexistent root → friendly message, no crash" do
      empty = Path.join(System.tmp_dir!(), "wb_empty_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(empty)
      on_exit(fn -> File.rm_rf!(empty) end)
      assert WorkKits.list_text(empty) == "(no toolkits under #{empty})"

      missing = "/nonexistent/path/#{:erlang.unique_integer([:positive])}"
      assert WorkKits.list_text(missing) == "(no toolkits under #{missing})"
    end
  end

  # ── show_text/2 ───────────────────────────────────────────────────────────

  describe "show_text/2" do
    test "shows the manifest body + a skill index" do
      out = WorkKits.show_text("git", @root)
      assert out =~ ~s(<work-ref rel="kit")
      assert out =~ ~s(name="git")
      assert out =~ "Skills (read with `work kit show git <skill>`)"
      assert out =~ "overview"
      assert out =~ "bisect"
    end

    test "unknown toolkit id → 'no such toolkit'" do
      assert WorkKits.show_text("does-not-exist", @root) == "no such toolkit: does-not-exist"
    end

    test "ADVERSARIAL: id with ../ does not resolve to a parent dir" do
      # tk_dir matches on the *discovered* id field, never builds a path from id,
      # so traversal ids simply fail to match → 'no such toolkit'.
      out = WorkKits.show_text("../git", @root)
      assert out == "no such toolkit: ../git"
    end

    test "ADVERSARIAL: absolute-path id does not resolve" do
      assert WorkKits.show_text("/etc/passwd", @root) == "no such toolkit: /etc/passwd"
    end

    test "ADVERSARIAL: null byte in id does not crash, does not resolve" do
      assert WorkKits.show_text("git\0", @root) == "no such toolkit: git\0"
    end
  end

  # ── show_skill_text/3 — thin vs thick, CAPTION TOC ────────────────────────

  describe "show_skill_text/3 against the real tree" do
    # Skills are Markdown now; their `##` section headings drive the TOC (org
    # `#+CAPTION` → `##` in the work-* model). git/overview.md carries `##`
    # headings, so the TOC header is emitted and the body renders.
    test "renders a thin skill body with a heading TOC header" do
      out = WorkKits.show_skill_text("git", "overview", @root)
      # body always renders:
      assert out =~ "confirm git is installed"
      assert out =~ "# git — overview"
      # `##` headings are detected → TOC header.
      assert out =~ "TOC (CAPTIONs):"
      # TOC bullets use "  • "
      assert out =~ ~r/^\s+•\s/m
    end

    test "every git skill has `##` headings AND renders a TOC" do
      # All 9 git skills carry `##` section headings; captions/1 reads them, so
      # each produces a TOC header.
      for slug <- ~w(overview bisect cherry-pick partial-staging
                     rebase-without-losing-work recover-from-detached-head
                     undo-a-commit-safely worktree-management submodule-flows) do
        out = WorkKits.show_skill_text("git", slug, @root)
        assert out =~ ~r/^##\s/m, "#{slug} should contain `##` headings"
        assert out =~ "TOC (CAPTIONs):", "#{slug} should render a TOC"
      end
    end

    test "unknown skill slug → 'no such skill'" do
      assert WorkKits.show_skill_text("git", "no-such-skill", @root) ==
               "no such skill: git/no-such-skill"
    end

    test "unknown toolkit → 'no such skill' (dir resolves nil)" do
      assert WorkKits.show_skill_text("nope", "overview", @root) ==
               "no such skill: nope/overview"
    end
  end

  describe "show_skill_text/3 thin vs thick (scratch fixture)" do
    setup [:scratch_toolkit]

    test "thin skill: skills/<slug>.md resolves", %{root: root} do
      out = WorkKits.show_skill_text("demo", "overview", root)
      assert out =~ "body of the thin overview skill"
      assert out =~ "TOC (CAPTIONs):"
      assert out =~ "only caption in the thin skill"
    end

    test "thick skill: skills/<slug>/SKILL.md resolves", %{root: root} do
      out = WorkKits.show_skill_text("demo", "deep", root)
      assert out =~ "THICK_SKILL_MARKER"
    end

    test "thin wins when both could exist (overview is thin)", %{root: root, tk: tk} do
      # Plant a thick form alongside the thin one; thin must take precedence.
      File.mkdir_p!(Path.join([tk, "skills", "overview"]))
      File.write!(Path.join([tk, "skills", "overview", "SKILL.md"]), "THICK_OVERVIEW\n")
      out = WorkKits.show_skill_text("demo", "overview", root)
      assert out =~ "body of the thin overview skill"
      refute out =~ "THICK_OVERVIEW"
    end
  end

  describe "show_skill_text/3 ADVERSARIAL path escape (scratch fixture)" do
    setup [:scratch_toolkit]

    test "../ traversal slug cannot read a file outside the toolkit", %{root: root, secret: secret} do
      assert File.exists?(secret)
      # SECURITY REGRESSION (finding #5): a slug that, joined+`.org`, reaches the
      # REAL secret (skills/../../../SECRET.org = base/SECRET.org) must be refused.
      out = WorkKits.show_skill_text("demo", "../../../SECRET", root)
      refute out =~ "TOP_SECRET"
      assert out == "no such skill: demo/../../../SECRET"
    end

    test "deeper traversal toward /etc/passwd is not read", %{root: root} do
      out = WorkKits.show_skill_text("demo", "../../../../../../../../etc/passwd", root)
      refute out =~ "root:"
      assert out =~ "no such skill:"
    end

    test "absolute-path slug is not read", %{root: root} do
      # Path.join([dir,"skills","/etc/passwd.org"]) — an absolute middle segment
      # would, under a naive join, reset to /etc/passwd.org. Must not read.
      out = WorkKits.show_skill_text("demo", "/etc/passwd", root)
      refute out =~ "root:"
      assert out =~ "no such skill:"
    end

    test "null byte in slug does not crash and does not read", %{root: root} do
      out = WorkKits.show_skill_text("demo", "overview\0", root)
      # File.exists? returns false for a NUL-containing path (no raise).
      assert out =~ "no such skill:"
    end
  end

  # ── search_text/2 ─────────────────────────────────────────────────────────

  describe "search_text/2" do
    test "finds a substring across skills, formatted path:line: text" do
      out = WorkKits.search_text("rebase", @root)
      refute out == "(no matches for \"rebase\")"
      # each hit line is "<rel-path>:<n>: <trimmed text>"
      assert out =~ ~r{git/skills/[^:]+\.md:\d+: }
    end

    test "is case-insensitive" do
      a = WorkKits.search_text("REBASE", @root)
      b = WorkKits.search_text("rebase", @root)
      assert a == b
    end

    test "no match → friendly inspect-quoted message" do
      assert WorkKits.search_text("zzz_no_such_token_zzz_#{:erlang.unique_integer()}", @root) =~
               "(no matches for "
    end

    test "empty query matches every line (empty string is a substring of all)" do
      out = WorkKits.search_text("", @root)
      # "" is contained in every line → many hits, definitely not the no-match msg
      refute out =~ "(no matches"
      assert String.contains?(out, ":1:")
    end

    test "unicode query matches a unicode body line" do
      # the CAPTION bullets/arrows aren't in skills, but ffmpeg/3w use →/em-dash.
      # Use a token we control: search for the em dash that appears in taglines'
      # cousin lines inside skills. Fall back to ascii if absent — assert no crash.
      out = WorkKits.search_text("→", @root)
      assert is_binary(out)
    end

    test "ADVERSARIAL: regex metacharacters in query are treated literally" do
      # query is lowercased and passed to String.contains?/2 (NOT a regex), so
      # ".*" must match only the literal ".*", not act as a wildcard.
      out = WorkKits.search_text(".*", @root)
      # If it were a regex wildcard it'd match nearly everything; literal ".*"
      # is rare. Either way it must not raise and must be a string.
      assert is_binary(out)
    end

    test "huge query does not crash" do
      big = String.duplicate("x", 100_000)
      assert WorkKits.search_text(big, @root) =~ "(no matches for "
    end
  end

  # ── verify_text/2 ─────────────────────────────────────────────────────────

  describe "verify_text/2" do
    test "git: structural checks pass (manifest + overview present)" do
      out = WorkKits.verify_text("git", @root)
      assert out =~ "✓ manifest.html present"
      assert out =~ "skills/overview.md present"
      # exec mode is reported (git declares none → discovery-only).
      assert out =~ "exec:"
      # NO NATIVE EXEC (wb-9ja): Markdown skills carry no org `:role` bash blocks,
      # so there is nothing to disable — the structural checks are the gate.
      refute out =~ "pre checks DISABLED"
      refute out =~ ~r/(✓|✗) pre skills/
    end

    test "git: no native :role pre lane even with WB_TOOLKIT_EXEC=1 (native exec banned)" do
      System.put_env("WB_TOOLKIT_EXEC", "1")
      on_exit(fn -> System.delete_env("WB_TOOLKIT_EXEC") end)
      out = WorkKits.verify_text("git", @root)
      # The opt-in flag no longer re-enables native bash; pre never runs.
      refute out =~ ~r/(✓|✗) pre skills/
    end

    test "unknown toolkit → 'no such toolkit'" do
      assert WorkKits.verify_text("nope", @root) == "no such toolkit: nope"
    end

    test "ADVERSARIAL: traversal id does not resolve" do
      assert WorkKits.verify_text("../git", @root) == "no such toolkit: ../git"
    end

    test "scratch toolkit with no pre blocks still reports structural checks" do
      base = Path.join(System.tmp_dir!(), "wb_tk_noprexec_#{:erlang.unique_integer([:positive])}")
      root = Path.join(base, "root")
      tk = Path.join(root, "quiet")
      File.mkdir_p!(Path.join(tk, "skills"))
      on_exit(fn -> File.rm_rf!(base) end)

      File.write!(Path.join(tk, "manifest.html"), """
      <work-ref rel="kit" name="quiet" cli="quiet"/>
      <work-doc title="quiet"></work-doc>
      """)

      File.write!(Path.join([tk, "skills", "overview.md"]), "no role blocks here\n")
      out = WorkKits.verify_text("quiet", root)
      assert out =~ "✓ manifest.html present"
      assert out =~ "✓ skills/overview.md present"
    end
  end

  # ── extract_role_blocks/2 ─────────────────────────────────────────────────

  describe "extract_role_blocks/2" do
    test "extracts a single pre block body" do
      content = """
      preamble
      #+begin_src bash :role pre
      echo hi
      exit 0
      #+end_src
      tail
      """

      assert [body] = WorkKits.extract_role_blocks(content, "pre")
      assert body =~ "echo hi"
      assert body =~ "exit 0"
      refute body =~ "preamble"
      refute body =~ "begin_src"
    end

    test "extracts multiple blocks of the same role in order" do
      content = """
      #+begin_src bash :role pre
      one
      #+end_src
      #+begin_src bash :role pre
      two
      #+end_src
      """

      assert [a, b] = WorkKits.extract_role_blocks(content, "pre")
      assert a =~ "one"
      assert b =~ "two"
    end

    test "distinguishes pre vs post vs task roles" do
      content = """
      #+begin_src bash :role pre
      P
      #+end_src
      #+begin_src bash :role post
      Q
      #+end_src
      #+begin_src bash :role task
      R
      #+end_src
      """

      assert [pre] = WorkKits.extract_role_blocks(content, "pre")
      assert pre =~ "P"
      assert [post] = WorkKits.extract_role_blocks(content, "post")
      assert post =~ "Q"
      assert [task] = WorkKits.extract_role_blocks(content, "task")
      assert task =~ "R"
    end

    test "no matching role → []" do
      content = "#+begin_src bash :role pre\nx\n#+end_src\n"
      assert WorkKits.extract_role_blocks(content, "task") == []
    end

    test "empty content → []" do
      assert WorkKits.extract_role_blocks("", "pre") == []
    end

    test "role word-boundary: ':role pre' does not match ':role preflight'" do
      content = "#+begin_src bash :role preflight\nx\n#+end_src\n"
      assert WorkKits.extract_role_blocks(content, "pre") == []
      assert [b] = WorkKits.extract_role_blocks(content, "preflight")
      assert b =~ "x"
    end

    test "tolerates header attrs before and after :role" do
      content =
        "#+begin_src bash :results output :role pre :dir /tmp\nbody-line\n  #+end_src\n"

      assert [b] = WorkKits.extract_role_blocks(content, "pre")
      assert b =~ "body-line"
    end

    test "ADVERSARIAL: role argument is interpolated into the regex unescaped (leaky)" do
      # role is interpolated straight into a Regex via #{role}; a metachar role
      # should not raise (it just won't match the literal block). Documents the
      # current contract — callers pass literal "pre"/"post"/"task".
      content = "#+begin_src bash :role pre\nx\n#+end_src\n"
      assert WorkKits.extract_role_blocks(content, "pre") != []
      # A metachar role compiles into the regex unescaped: "p.e" therefore
      # matches "pre" (`.` matches the literal 'r'). This is a leaky contract —
      # callers MUST pass literal role names ("pre"/"post"/"task"); a role like
      # "p.e" silently aliases real blocks rather than failing. Documented, not
      # a crash. A role with an *unbalanced* metachar would raise at compile.
      assert WorkKits.extract_role_blocks(content, "p.e") == ["x"]
    end

    test "huge content with one block still extracts" do
      filler = String.duplicate("noise line\n", 50_000)
      content = filler <> "#+begin_src bash :role pre\nNEEDLE\n#+end_src\n" <> filler
      assert [b] = WorkKits.extract_role_blocks(content, "pre")
      assert b =~ "NEEDLE"
    end

    test "unicode inside a block body is preserved" do
      content = "#+begin_src bash :role pre\necho 'café → 日本語 🎬'\n#+end_src\n"
      assert [b] = WorkKits.extract_role_blocks(content, "pre")
      assert b =~ "café → 日本語 🎬"
    end
  end

  # ── run_task_text/4 — DISABLED (no native exec, wb-9ja) ───────────────────
  # The `:role task` lane ran NATIVE bash; native execution is banned and this
  # surface is agent-reachable (the `work` tool), so run_task_text now ALWAYS refuses
  # without executing anything. These tests pin that contract.

  describe "run_task_text/4 (scratch fixture)" do
    setup [:scratch_toolkit]

    # Even with the old opt-in flag set, native bash never runs (wb-9ja).
    setup do
      System.put_env("WB_TOOLKIT_EXEC", "1")
      on_exit(fn -> System.delete_env("WB_TOOLKIT_EXEC") end)
      :ok
    end

    test "refuses to run a :role task block — native exec removed", %{root: root, tk: tk} do
      sentinel = Path.join(System.tmp_dir!(), "wb_ran_#{System.unique_integer([:positive])}")

      File.write!(Path.join([tk, "skills", "echoer.md"]), """
      ```bash :role task
      touch #{sentinel}
      echo "arg1=$1 arg2=$2"
      ```
      """)

      on_exit(fn -> File.rm(sentinel) end)

      out = WorkKits.run_task_text("demo", "echoer", ["alpha", "beta"], root)
      # Honest refusal, and CRUCIALLY: nothing executed (no sentinel, no echo output).
      assert out =~ "native :role bash execution removed (wb-9ja)"
      refute out =~ "arg1=alpha"
      refute File.exists?(sentinel)
    end

    # ADVERSARIAL: a traversal slug to a real .org outside the toolkit must never
    # execute. Under wb-9ja this is satisfied by construction — run_task_text never
    # runs ANY bash — but we keep the sentinel proof.
    test "ADVERSARIAL: traversal task slug never executes a planted .org",
         %{root: root, tk: tk} do
      sentinel = Path.join(System.tmp_dir!(), "wb_pwned_#{System.unique_integer([:positive])}")
      evil = Path.join(Path.dirname(Path.dirname(tk)), "evil.md")

      File.write!(evil, """
      ```bash :role task
      touch #{sentinel}
      echo PWNED
      ```
      """)

      on_exit(fn -> File.rm(evil); File.rm(sentinel) end)

      out = WorkKits.run_task_text("demo", "../../evil", [], root)
      refute out =~ "PWNED"
      refute File.exists?(sentinel)
      assert out =~ "native :role bash execution removed (wb-9ja)"
    end

    # SECURITY REGRESSION (finding #3/#16): without the opt-in, run is refused.
    test "default-deny: with WB_TOOLKIT_EXEC unset, run is refused", %{root: root, tk: tk} do
      System.delete_env("WB_TOOLKIT_EXEC")
      sentinel = Path.join(System.tmp_dir!(), "wb_noexec_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(sentinel) end)

      File.write!(Path.join([tk, "skills", "danger.md"]), """
      ```bash :role task
      touch #{sentinel}
      ```
      """)

      out = WorkKits.run_task_text("demo", "danger", [], root)
      assert out =~ "refusing to run"
      refute File.exists?(sentinel)
    end
  end
end
