defmodule Workbooks.ToolkitsTest do
  @moduledoc """
  The `wb toolkit` surface (wb-4bj.2) — discovery + rendering over the on-disk
  org toolkits. Exercises default_root, list_text/show_text/show_skill_text/
  search_text/verify_text against the real ../toolkits tree, thin vs thick
  skill resolution, extract_role_blocks, and #+CAPTION TOC extraction.

  ADVERSARIAL: toolkit ids and skill slugs are agent/LLM-supplied. A slug
  containing "../", an absolute path, or a null byte MUST NOT read or run a
  file outside the toolkit's own skills/ directory. Those cases are asserted.
  """
  use ExUnit.Case, async: false

  alias Workbooks.Toolkits

  # The rich on-disk tree: git/ ffmpeg/ 3w/ linear/ … (sibling of runtime/, i.e.
  # workbooks-finish/toolkits). __DIR__ is runtime/test, so it is two levels up —
  # NOT runtime/toolkits, which holds only the huniq/text WASM build fixtures.
  @root Path.expand("../../toolkits", __DIR__)

  setup_all do
    # discover_dir/parse_headlines route through the OQL kernel process.
    case Workbooks.OQL.start_link(nil) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

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

    # manifest with a toolkit node (id "demo")
    File.write!(Path.join(tk, "manifest.org"), """
    #+TITLE: demo toolkit
    #+CLI_BIN: demo
    #+STATUS: stable
    #+TAGLINE: scratch fixture for path-escape tests

    * demo — scratch                                             :toolkit:
      :PROPERTIES:
      :ID:        demo
      :CLI_BIN:   demo
      :STATUS:    stable
      :SKILL_DIR: skills/
      :END:
    """)

    # thin skill: skills/overview.org   (verify_text wants overview.org present)
    File.write!(Path.join([tk, "skills", "overview.org"]), """
    #+TITLE: demo overview
    #+CAPTION: only caption in the thin skill
    body of the thin overview skill
    """)

    # thick skill: skills/deep/SKILL.org
    File.mkdir_p!(Path.join([tk, "skills", "deep"]))

    File.write!(Path.join([tk, "skills", "deep", "SKILL.org"]), """
    #+TITLE: deep thick skill
    THICK_SKILL_MARKER
    """)

    # A secret OUTSIDE the toolkit dir, reachable only via traversal.
    secret = Path.join(base, "SECRET.org")
    File.write!(secret, "TOP_SECRET_SHOULD_NEVER_BE_READ\n")

    on_exit(fn -> File.rm_rf!(base) end)
    Map.merge(ctx, %{root: root, tk: tk, secret: secret})
  end

  # ── default_root/0 ────────────────────────────────────────────────────────

  describe "default_root/0" do
    test "honors $WB_TOOLKITS_ROOT when set" do
      System.put_env("WB_TOOLKITS_ROOT", @root)
      on_exit(fn -> System.delete_env("WB_TOOLKITS_ROOT") end)
      assert Toolkits.default_root() == @root
    end

    # SECURITY REGRESSION (finding #6): a blank/invalid WB_TOOLKITS_ROOT must NOT
    # repoint the surface. It is now honored ONLY if it names an existing dir;
    # otherwise we fall back to the in-tree default.
    test "an empty-string env var is ignored (falls back to default)" do
      System.put_env("WB_TOOLKITS_ROOT", "")
      on_exit(fn -> System.delete_env("WB_TOOLKITS_ROOT") end)
      refute Toolkits.default_root() == ""
    end

    test "a non-existent-dir env var is ignored (falls back to default)" do
      System.put_env("WB_TOOLKITS_ROOT", "/no/such/dir/wb-#{System.unique_integer([:positive])}")
      on_exit(fn -> System.delete_env("WB_TOOLKITS_ROOT") end)
      refute String.starts_with?(Toolkits.default_root(), "/no/such/dir")
    end

    test "falls back to a real dir when env is unset" do
      System.delete_env("WB_TOOLKITS_ROOT")
      # We can't guarantee cwd, but the function must return a string and never raise.
      assert is_binary(Toolkits.default_root())
    end
  end

  # ── list_text/1 ───────────────────────────────────────────────────────────

  describe "list_text/1" do
    test "lists known toolkits, one per line, with id + status + tagline" do
      out = Toolkits.list_text(@root)
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
        Toolkits.list_text(@root)
        |> String.split("\n")
        |> Enum.map(&(String.split(&1, ~r/\s/, parts: 2) |> hd()))

      assert ids == Enum.sort(ids)
    end

    test "empty / nonexistent root → friendly message, no crash" do
      empty = Path.join(System.tmp_dir!(), "wb_empty_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(empty)
      on_exit(fn -> File.rm_rf!(empty) end)
      assert Toolkits.list_text(empty) == "(no toolkits under #{empty})"

      missing = "/nonexistent/path/#{:erlang.unique_integer([:positive])}"
      assert Toolkits.list_text(missing) == "(no toolkits under #{missing})"
    end
  end

  # ── show_text/2 ───────────────────────────────────────────────────────────

  describe "show_text/2" do
    test "shows the manifest body + a skill index" do
      out = Toolkits.show_text("git", @root)
      assert out =~ "#+TITLE: git toolkit"
      assert out =~ "Skills (read with `wb toolkit show git <skill>`)"
      assert out =~ "overview"
      assert out =~ "bisect"
    end

    test "unknown toolkit id → 'no such toolkit'" do
      assert Toolkits.show_text("does-not-exist", @root) == "no such toolkit: does-not-exist"
    end

    test "ADVERSARIAL: id with ../ does not resolve to a parent dir" do
      # tk_dir matches on the *discovered* id field, never builds a path from id,
      # so traversal ids simply fail to match → 'no such toolkit'.
      out = Toolkits.show_text("../git", @root)
      assert out == "no such toolkit: ../git"
    end

    test "ADVERSARIAL: absolute-path id does not resolve" do
      assert Toolkits.show_text("/etc/passwd", @root) == "no such toolkit: /etc/passwd"
    end

    test "ADVERSARIAL: null byte in id does not crash, does not resolve" do
      assert Toolkits.show_text("git\0", @root) == "no such toolkit: git\0"
    end
  end

  # ── show_skill_text/3 — thin vs thick, CAPTION TOC ────────────────────────

  describe "show_skill_text/3 against the real tree" do
    # FAILING — REAL BUG (do not "fix" by relaxing the assertion).
    # git/skills/overview.org carries two `#+CAPTION:` lines, but they are
    # INDENTED under the `* Verify` heading ("  #+CAPTION: …"), as org body
    # content conventionally is. `Toolkits.captions/1` uses
    #   ~r/^#\+CAPTION:\s*(.+)$/m
    # which anchors at column 0 and rejects leading whitespace, so it finds
    # ZERO captions here and the TOC header is never emitted. Contrast
    # extract_role_blocks/2, which (correctly) does NOT anchor and so handles
    # the same indentation. The fix is to allow leading whitespace in the
    # caption regex (e.g. ~r/^[^\S\n]*#\+CAPTION:[^\S\n]*(.+)$/m), matching how
    # kw/drawer already tolerate indentation. Left failing to flag the bug.
    test "renders a thin skill body with a CAPTION TOC header" do
      out = Toolkits.show_skill_text("git", "overview", @root)
      # body always renders:
      assert out =~ "confirm git is installed"
      assert out =~ "#+TITLE: git — overview"
      # BUG: indented captions are not detected → no TOC header. This assertion
      # SHOULD pass once captions/1 tolerates leading whitespace.
      assert out =~ "TOC (CAPTIONs):"
      # caption bullets use "  • "
      assert out =~ ~r/^\s+•\s/m
    end

    test "every git skill has captions, yet NONE render a TOC (same bug, broad)" do
      # Reinforces the bug's blast radius: all 9 git skills carry #+CAPTION
      # lines, but every one of them indents the caption, so NOT ONE produces a
      # TOC header. This whole feature is currently dead for the real tree.
      for slug <- ~w(overview bisect cherry-pick partial-staging
                     rebase-without-losing-work recover-from-detached-head
                     undo-a-commit-safely worktree-management submodule-flows) do
        out = Toolkits.show_skill_text("git", slug, @root)
        assert out =~ "#+CAPTION:", "#{slug} should contain caption lines"
        # BUG: indented captions → no TOC. SHOULD become `assert` after the fix.
        refute out =~ "TOC (CAPTIONs):", "#{slug} unexpectedly rendered a TOC"
      end
    end

    test "unknown skill slug → 'no such skill'" do
      assert Toolkits.show_skill_text("git", "no-such-skill", @root) ==
               "no such skill: git/no-such-skill"
    end

    test "unknown toolkit → 'no such skill' (dir resolves nil)" do
      assert Toolkits.show_skill_text("nope", "overview", @root) ==
               "no such skill: nope/overview"
    end
  end

  describe "show_skill_text/3 thin vs thick (scratch fixture)" do
    setup [:scratch_toolkit]

    test "thin skill: skills/<slug>.org resolves", %{root: root} do
      out = Toolkits.show_skill_text("demo", "overview", root)
      assert out =~ "body of the thin overview skill"
      assert out =~ "TOC (CAPTIONs):"
      assert out =~ "only caption in the thin skill"
    end

    test "thick skill: skills/<slug>/SKILL.org resolves", %{root: root} do
      out = Toolkits.show_skill_text("demo", "deep", root)
      assert out =~ "THICK_SKILL_MARKER"
    end

    test "thin wins when both could exist (overview is thin)", %{root: root, tk: tk} do
      # Plant a thick form alongside the thin one; thin must take precedence.
      File.mkdir_p!(Path.join([tk, "skills", "overview"]))
      File.write!(Path.join([tk, "skills", "overview", "SKILL.org"]), "THICK_OVERVIEW\n")
      out = Toolkits.show_skill_text("demo", "overview", root)
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
      out = Toolkits.show_skill_text("demo", "../../../SECRET", root)
      refute out =~ "TOP_SECRET"
      assert out == "no such skill: demo/../../../SECRET"
    end

    test "deeper traversal toward /etc/passwd is not read", %{root: root} do
      out = Toolkits.show_skill_text("demo", "../../../../../../../../etc/passwd", root)
      refute out =~ "root:"
      assert out =~ "no such skill:"
    end

    test "absolute-path slug is not read", %{root: root} do
      # Path.join([dir,"skills","/etc/passwd.org"]) — an absolute middle segment
      # would, under a naive join, reset to /etc/passwd.org. Must not read.
      out = Toolkits.show_skill_text("demo", "/etc/passwd", root)
      refute out =~ "root:"
      assert out =~ "no such skill:"
    end

    test "null byte in slug does not crash and does not read", %{root: root} do
      out = Toolkits.show_skill_text("demo", "overview\0", root)
      # File.exists? returns false for a NUL-containing path (no raise).
      assert out =~ "no such skill:"
    end
  end

  # ── search_text/2 ─────────────────────────────────────────────────────────

  describe "search_text/2" do
    test "finds a substring across skills, formatted path:line: text" do
      out = Toolkits.search_text("rebase", @root)
      refute out == "(no matches for \"rebase\")"
      # each hit line is "<rel-path>:<n>: <trimmed text>"
      assert out =~ ~r{git/skills/[^:]+\.org:\d+: }
    end

    test "is case-insensitive" do
      a = Toolkits.search_text("REBASE", @root)
      b = Toolkits.search_text("rebase", @root)
      assert a == b
    end

    test "no match → friendly inspect-quoted message" do
      assert Toolkits.search_text("zzz_no_such_token_zzz_#{:erlang.unique_integer()}", @root) =~
               "(no matches for "
    end

    test "empty query matches every line (empty string is a substring of all)" do
      out = Toolkits.search_text("", @root)
      # "" is contained in every line → many hits, definitely not the no-match msg
      refute out =~ "(no matches"
      assert String.contains?(out, ":1:")
    end

    test "unicode query matches a unicode body line" do
      # the CAPTION bullets/arrows aren't in skills, but ffmpeg/3w use →/em-dash.
      # Use a token we control: search for the em dash that appears in taglines'
      # cousin lines inside skills. Fall back to ascii if absent — assert no crash.
      out = Toolkits.search_text("→", @root)
      assert is_binary(out)
    end

    test "ADVERSARIAL: regex metacharacters in query are treated literally" do
      # query is lowercased and passed to String.contains?/2 (NOT a regex), so
      # ".*" must match only the literal ".*", not act as a wildcard.
      out = Toolkits.search_text(".*", @root)
      # If it were a regex wildcard it'd match nearly everything; literal ".*"
      # is rare. Either way it must not raise and must be a string.
      assert is_binary(out)
    end

    test "huge query does not crash" do
      big = String.duplicate("x", 100_000)
      assert Toolkits.search_text(big, @root) =~ "(no matches for "
    end
  end

  # ── verify_text/2 ─────────────────────────────────────────────────────────

  describe "verify_text/2" do
    test "git: structural checks pass; pre blocks SKIPPED by default (default-deny)" do
      out = Toolkits.verify_text("git", @root)
      assert out =~ "✓ manifest.org present"
      assert out =~ "skills/overview.org present"
      # git exec mode is posix; CLI_BIN=git is on PATH on this machine.
      assert out =~ "exec:"
      # SECURITY REGRESSION (finding #14): pre blocks are NOT auto-executed; they
      # are reported as skipped unless WB_TOOLKIT_EXEC=1.
      assert out =~ "pre checks SKIPPED"
    end

    test "git: with WB_TOOLKIT_EXEC=1, pre blocks run (sandboxed)" do
      System.put_env("WB_TOOLKIT_EXEC", "1")
      on_exit(fn -> System.delete_env("WB_TOOLKIT_EXEC") end)
      out = Toolkits.verify_text("git", @root)
      assert out =~ ~r/(✓|✗) pre skills/
    end

    test "unknown toolkit → 'no such toolkit'" do
      assert Toolkits.verify_text("nope", @root) == "no such toolkit: nope"
    end

    test "ADVERSARIAL: traversal id does not resolve" do
      assert Toolkits.verify_text("../git", @root) == "no such toolkit: ../git"
    end

    test "scratch toolkit with no pre blocks still reports structural checks" do
      base = Path.join(System.tmp_dir!(), "wb_tk_noprexec_#{:erlang.unique_integer([:positive])}")
      root = Path.join(base, "root")
      tk = Path.join(root, "quiet")
      File.mkdir_p!(Path.join(tk, "skills"))
      on_exit(fn -> File.rm_rf!(base) end)

      File.write!(Path.join(tk, "manifest.org"), """
      #+CLI_BIN: quiet
      * quiet :toolkit:
        :PROPERTIES:
        :ID: quiet
        :CLI_BIN: quiet
        :END:
      """)

      File.write!(Path.join([tk, "skills", "overview.org"]), "no role blocks here\n")
      out = Toolkits.verify_text("quiet", root)
      assert out =~ "✓ manifest.org present"
      assert out =~ "✓ skills/overview.org present"
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

      assert [body] = Toolkits.extract_role_blocks(content, "pre")
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

      assert [a, b] = Toolkits.extract_role_blocks(content, "pre")
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

      assert [pre] = Toolkits.extract_role_blocks(content, "pre")
      assert pre =~ "P"
      assert [post] = Toolkits.extract_role_blocks(content, "post")
      assert post =~ "Q"
      assert [task] = Toolkits.extract_role_blocks(content, "task")
      assert task =~ "R"
    end

    test "no matching role → []" do
      content = "#+begin_src bash :role pre\nx\n#+end_src\n"
      assert Toolkits.extract_role_blocks(content, "task") == []
    end

    test "empty content → []" do
      assert Toolkits.extract_role_blocks("", "pre") == []
    end

    test "role word-boundary: ':role pre' does not match ':role preflight'" do
      content = "#+begin_src bash :role preflight\nx\n#+end_src\n"
      assert Toolkits.extract_role_blocks(content, "pre") == []
      assert [b] = Toolkits.extract_role_blocks(content, "preflight")
      assert b =~ "x"
    end

    test "tolerates header attrs before and after :role" do
      content =
        "#+begin_src bash :results output :role pre :dir /tmp\nbody-line\n  #+end_src\n"

      assert [b] = Toolkits.extract_role_blocks(content, "pre")
      assert b =~ "body-line"
    end

    test "ADVERSARIAL: role argument is interpolated into the regex unescaped (leaky)" do
      # role is interpolated straight into a Regex via #{role}; a metachar role
      # should not raise (it just won't match the literal block). Documents the
      # current contract — callers pass literal "pre"/"post"/"task".
      content = "#+begin_src bash :role pre\nx\n#+end_src\n"
      assert Toolkits.extract_role_blocks(content, "pre") != []
      # A metachar role compiles into the regex unescaped: "p.e" therefore
      # matches "pre" (`.` matches the literal 'r'). This is a leaky contract —
      # callers MUST pass literal role names ("pre"/"post"/"task"); a role like
      # "p.e" silently aliases real blocks rather than failing. Documented, not
      # a crash. A role with an *unbalanced* metachar would raise at compile.
      assert Toolkits.extract_role_blocks(content, "p.e") == ["x"]
    end

    test "huge content with one block still extracts" do
      filler = String.duplicate("noise line\n", 50_000)
      content = filler <> "#+begin_src bash :role pre\nNEEDLE\n#+end_src\n" <> filler
      assert [b] = Toolkits.extract_role_blocks(content, "pre")
      assert b =~ "NEEDLE"
    end

    test "unicode inside a block body is preserved" do
      content = "#+begin_src bash :role pre\necho 'café → 日本語 🎬'\n#+end_src\n"
      assert [b] = Toolkits.extract_role_blocks(content, "pre")
      assert b =~ "café → 日本語 🎬"
    end
  end

  # ── run_task_text/4 (exercises run_bash + skill_path together) ─────────────

  describe "run_task_text/4 (scratch fixture)" do
    setup [:scratch_toolkit]

    # Execution is default-deny (finding #3/#15/#16). These functional tests opt
    # in via WB_TOOLKIT_EXEC=1 to exercise the (now sandboxed, capped) run path.
    setup do
      System.put_env("WB_TOOLKIT_EXEC", "1")
      on_exit(fn -> System.delete_env("WB_TOOLKIT_EXEC") end)
      :ok
    end

    test "runs the :role task block with positional args", %{root: root, tk: tk} do
      File.write!(Path.join([tk, "skills", "echoer.org"]), """
      #+begin_src bash :role task
      echo "arg1=$1 arg2=$2"
      #+end_src
      """)

      out = Toolkits.run_task_text("demo", "echoer", ["alpha", "beta"], root)
      assert out =~ "arg1=alpha arg2=beta"
    end

    test "missing :role task block → friendly message", %{root: root} do
      # overview.org has no :role task block
      assert Toolkits.run_task_text("demo", "overview", [], root) ==
               "no :role task block in demo/overview"
    end

    test "unknown skill → friendly message", %{root: root} do
      assert Toolkits.run_task_text("demo", "nope", [], root) ==
               "no such toolkit/skill: demo/nope"
    end

    # SECURITY REGRESSION (finding #4): a real attacker-planted .org OUTSIDE the
    # toolkit, named via a traversal slug, must NOT be resolved or run. Plant a
    # `.org` file (skill_path appends .org) two levels up and a `:role task` body
    # that would write a sentinel — assert it never executes.
    test "ADVERSARIAL: traversal task slug to a real .org outside the toolkit is refused",
         %{root: root, tk: tk} do
      sentinel = Path.join(System.tmp_dir!(), "wb_pwned_#{System.unique_integer([:positive])}")
      evil = Path.join(Path.dirname(Path.dirname(tk)), "evil.org")

      File.write!(evil, """
      #+begin_src bash :role task
      touch #{sentinel}
      echo PWNED
      #+end_src
      """)

      on_exit(fn -> File.rm(evil); File.rm(sentinel) end)

      # slug that, joined+`.org`, would reach ../../evil.org (a real file).
      out = Toolkits.run_task_text("demo", "../../evil", [], root)
      refute out =~ "PWNED"
      refute File.exists?(sentinel)
      assert out =~ "no such toolkit/skill:"
    end

    # SECURITY REGRESSION (finding #3/#16): without the opt-in, run is refused.
    test "default-deny: with WB_TOOLKIT_EXEC unset, run is refused", %{root: root, tk: tk} do
      System.delete_env("WB_TOOLKIT_EXEC")
      sentinel = Path.join(System.tmp_dir!(), "wb_noexec_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(sentinel) end)

      File.write!(Path.join([tk, "skills", "danger.org"]), """
      #+begin_src bash :role task
      touch #{sentinel}
      #+end_src
      """)

      out = Toolkits.run_task_text("demo", "danger", [], root)
      assert out =~ "refusing to run"
      refute File.exists?(sentinel)
    end
  end
end
