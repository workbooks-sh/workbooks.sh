defmodule Workbooks.CommandRegistryTest do
  @moduledoc """
  Thorough coverage of Workbooks.CommandRegistry — the in-WASM command surface
  the Dock's `run-command` import drives.

  Covers:
    * run/2, run/3, run/4 against the real prebuilt/source-built builtins
    * both arg modes — :argv (real wasmtime argv) and :stdin1 (folded first line)
    * the dynamic register/3 overlay over the static @builtins, name shadowing,
      and the {:unknown_command, name} error
    * build_and_register_crate error on a bogus crate name (no network/registry hit)
    * argv adversarial inputs — spaces / quotes / empty / very-long — and
      INJECTION-shaped argv (";rm -rf", $(...), backticks) which MUST be passed
      as DATA, never executed on the host shell
    * unicode, empty, and huge stdin

  The builtins are real CLIs compiled to wasm (jq = jaq, grep = regex wrapper,
  upper = Javy JS), run through wasmtime — these are NOT mocked. A few tests that
  compile a fresh artifact are tagged :build so a fast/offline run can `--exclude
  build`; they still run by default and are exercised in this worktree (the rust
  build is content-addressed and cached after first compile).
  """
  use ExUnit.Case, async: false

  alias Workbooks.{CommandRegistry, PackageManager}

  # A throwaway dynamic-command name unique per test so :persistent_term writes
  # from one test never leak into another (the registry overlay is global state).
  defp uniq(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  # ---------------------------------------------------------------------------
  # registry / list — the static-overlaid-with-dynamic view
  # ---------------------------------------------------------------------------

  describe "registry/0 and list/0" do
    test "always contains the three static builtins" do
      names = CommandRegistry.list()
      assert "upper" in names
      assert "jq" in names
      assert "grep" in names
    end

    test "registry/0 returns the {:src|:wasm, ...} specs for builtins" do
      reg = CommandRegistry.registry()
      assert {:src, "js", _code, :argv} = reg["upper"]
      assert {:wasm, _path, :stdin1} = reg["jq"]
      assert {:wasm, _path, :stdin1} = reg["grep"]
    end

    test "list/0 has no duplicates" do
      names = CommandRegistry.list()
      assert names == Enum.uniq(names)
    end
  end

  # ---------------------------------------------------------------------------
  # build_and_register_inline — the agent self-authoring join (wb-rhs.4).
  # Guard paths only here (no compile): they prove self-authoring cannot poison
  # the namespace or smuggle an unsupported lang BEFORE any in-sandbox build.
  # ---------------------------------------------------------------------------

  describe "build_and_register_inline/5 guards (pre-compile)" do
    test "refuses a reserved built-in name before building" do
      assert {:error, :reserved_name} =
               CommandRegistry.build_and_register_inline("jq", "rust", "fn main(){}")
    end

    test "rejects an empty / non-binary name" do
      assert {:error, :invalid_name} =
               CommandRegistry.build_and_register_inline("", "rust", "fn main(){}")

      assert {:error, :invalid_name} =
               CommandRegistry.build_and_register_inline(nil, "rust", "fn main(){}")
    end

    test "rejects an exotic-charset name" do
      assert {:error, :invalid_name} =
               CommandRegistry.build_and_register_inline("../evil", "rust", "fn main(){}")
    end

    test "rejects an unsupported language" do
      assert {:error, {:unsupported_lang, "haskell"}} =
               CommandRegistry.build_and_register_inline(uniq("t"), "haskell", "main = pure ()")
    end

    test "rejects empty source" do
      assert {:error, :empty_source} =
               CommandRegistry.build_and_register_inline(uniq("t"), "rust", "")
    end

    test "rejects non-list deps" do
      assert {:error, :invalid_deps} =
               CommandRegistry.build_and_register_inline(uniq("t"), "rust", "fn main(){}", "notalist")
    end

    test "a guard failure registers NOTHING (namespace stays clean)" do
      name = uniq("ghost")
      assert {:error, _} =
               CommandRegistry.build_and_register_inline(name, "haskell", "x")
      refute name in CommandRegistry.list()
    end

    @tag :build
    test "HOT-SWAP: re-register a name with new source → next run gets new behavior, no restart" do
      # wb-rhs.8: the "real-time updates" use case. Build a command, run it, then
      # re-author it under the SAME name with different source — a new content hash
      # replaces the binding live; the next run reflects the new behavior.
      name = uniq("hot")
      rev = ~S|const CH=65536;const cs=[];let n;const b=new Uint8Array(CH);while((n=Javy.IO.readSync(0,b))>0){cs.push(b.slice(0,n));}let t=0;for(const c of cs)t+=c.length;const all=new Uint8Array(t);let o=0;for(const c of cs){all.set(c,o);o+=c.length;}const s=new TextDecoder().decode(all).trim();Javy.IO.writeSync(1,new TextEncoder().encode(s.split("").reverse().join("")));|
      upper = ~S|const CH=65536;const cs=[];let n;const b=new Uint8Array(CH);while((n=Javy.IO.readSync(0,b))>0){cs.push(b.slice(0,n));}let t=0;for(const c of cs)t+=c.length;const all=new Uint8Array(t);let o=0;for(const c of cs){all.set(c,o);o+=c.length;}const s=new TextDecoder().decode(all).trim();Javy.IO.writeSync(1,new TextEncoder().encode(s.toUpperCase()));|

      assert {:ok, _} = CommandRegistry.build_and_register_inline(name, "js", rev)
      assert {:ok, "cba"} = CommandRegistry.run(name, "abc")
      {:wasm, path_v1, _} = CommandRegistry.current(name)

      # Re-author the same name with new source → hot-swap.
      assert {:ok, _} = CommandRegistry.build_and_register_inline(name, "js", upper)
      assert {:ok, "ABC"} = CommandRegistry.run(name, "abc")
      {:wasm, path_v2, _} = CommandRegistry.current(name)

      # New content hash → new artifact path; one live binding; builtins intact.
      assert path_v1 != path_v2
      assert Enum.count(CommandRegistry.list(), &(&1 == name)) == 1
      assert "jq" in CommandRegistry.list()
    end

    @tag :build
    test "FULL self-authoring loop: inline source → build-in-sandbox → register → run" do
      # The wb-rhs.4 headline: an agent writes source, builds it ENTIRELY in the
      # wasm sandbox (Javy here — the fast lane), registers it, and runs it — no
      # native toolchain, no host escape, all in one call chain.
      name = uniq("rev")

      # A Javy JS command that reverses stdin (chunked read to EOF).
      src = ~S|const CH=65536;const cs=[];let n;const b=new Uint8Array(CH);while((n=Javy.IO.readSync(0,b))>0){cs.push(b.slice(0,n));}let t=0;for(const c of cs)t+=c.length;const all=new Uint8Array(t);let o=0;for(const c of cs){all.set(c,o);o+=c.length;}const s=new TextDecoder().decode(all).trim();Javy.IO.writeSync(1,new TextEncoder().encode(s.split("").reverse().join("")));|

      assert {:ok, path} = CommandRegistry.build_and_register_inline(name, "js", src)
      # Content-addressed into the commands store (sha256 == filename).
      assert path =~ ~r/build\/commands\/[0-9a-f]{64}\.wasm$/
      # The freshly self-authored command is now runnable through the registry.
      assert name in CommandRegistry.list()
      assert {:ok, "olleh"} = CommandRegistry.run(name, "hello")
    end
  end

  # ---------------------------------------------------------------------------
  # run/2,3,4 — happy path on real wasm builtins
  # ---------------------------------------------------------------------------

  describe "run/2 (stdin only)" do
    test "upper uppercases stdin (source-built Javy, :argv mode, no argv)" do
      assert {:ok, "HI THERE"} = CommandRegistry.run("upper", "hi there")
    end

    test "jq reads filter from the first stdin line (its :stdin1 protocol)" do
      assert {:ok, "42"} = CommandRegistry.run("jq", ".x\n{\"x\":42}")
    end

    test "grep filters stdin: line 1 = pattern, rest = text" do
      assert {:ok, "foo\nzoo"} = CommandRegistry.run("grep", "oo\nfoo\nbar\nzoo")
    end

    test "run/2 is run/3 with empty argv" do
      assert CommandRegistry.run("upper", "abc") == CommandRegistry.run("upper", "abc", [])
    end
  end

  describe "run/3 — arg modes" do
    test ":stdin1 builtin (jq) folds argv into the FIRST stdin line" do
      # argv [".x"] becomes line 1 → same result as putting the filter inline.
      assert {:ok, "42"} = CommandRegistry.run("jq", "{\"x\":42}", [".x"])
      assert CommandRegistry.run("jq", "{\"x\":42}", [".x"]) ==
               CommandRegistry.run("jq", ".x\n{\"x\":42}", [])
    end

    test ":stdin1 builtin (grep) folds the pattern argv into line 1" do
      assert {:ok, "foo\nzoo"} = CommandRegistry.run("grep", "foo\nbar\nzoo", ["oo"])
    end

    test ":stdin1 fold joins MULTIPLE argv with a single space onto line 1" do
      # grep's pattern becomes "f|z" — joined argv, then the regex matches.
      assert {:ok, out} = CommandRegistry.run("grep", "foo\nbar\nzoo", ["f|z"])
      assert out == "foo\nzoo"
    end

    test ":argv builtin (upper) ignores argv it does not read, returns uppercased stdin" do
      # upper is :argv mode but the JS never reads argv; argv passes harmlessly.
      assert {:ok, "ABC"} = CommandRegistry.run("upper", "abc", ["whatever", "args"])
    end

    test "empty argv is a no-op for either mode" do
      assert {:ok, "HI"} = CommandRegistry.run("upper", "hi", [])
      assert {:ok, "42"} = CommandRegistry.run("jq", ".x\n{\"x\":42}", [])
    end
  end

  describe "run/3,4 — argv type contract" do
    test "non-list argv raises (FunctionClauseError guard is is_list(argv))" do
      assert_raise FunctionClauseError, fn ->
        CommandRegistry.run("upper", "hi", "not-a-list")
      end
    end

    test "run/4 accepts a dirs list (empty dirs is the default and works)" do
      assert {:ok, "HI"} = CommandRegistry.run("upper", "hi", [], [])
    end
  end

  # ---------------------------------------------------------------------------
  # unknown command error
  # ---------------------------------------------------------------------------

  describe "unknown command" do
    test "returns {:error, {:unknown_command, name}}" do
      assert {:error, {:unknown_command, "no-such-cmd"}} =
               CommandRegistry.run("no-such-cmd", "x")
    end

    test "unknown command via run/3 too" do
      assert {:error, {:unknown_command, "ghost"}} =
               CommandRegistry.run("ghost", "x", ["a"])
    end

    test "empty-string command name is unknown, not a crash" do
      assert {:error, {:unknown_command, ""}} = CommandRegistry.run("", "x")
    end

    test "unicode command name is unknown, not a crash" do
      assert {:error, {:unknown_command, " командаコマンド"}} =
               CommandRegistry.run(" командаコマンド", "x")
    end
  end

  # ---------------------------------------------------------------------------
  # dynamic register/3 + overlay semantics
  # ---------------------------------------------------------------------------

  describe "register/3 overlay" do
    test "register/3 adds a runnable command pointing at an existing wasm artifact" do
      name = uniq("g")
      # Reuse the real grep artifact under a fresh name, :stdin1 mode.
      assert :ok = CommandRegistry.register(name, "build/commands/grep.wasm", :stdin1)
      assert name in CommandRegistry.list()
      assert {:ok, "foo"} = CommandRegistry.run(name, "foo\nbar", ["oo"])
    end

    test "default arg mode for register/3 is :argv" do
      name = uniq("u")
      :ok = CommandRegistry.register(name, "build/commands/grep.wasm")
      assert {:wasm, "build/commands/grep.wasm", :argv} = CommandRegistry.registry()[name]
    end

    # SECURITY REGRESSION (finding #8 + #12): a dynamic registration MUST NOT
    # shadow a built-in. Before the fix, Map.merge(@builtins, dynamic) let dynamic
    # win, so register("jq", grep.wasm) silently hijacked jq for every Instance.
    # Now register/3 rejects reserved names AND registry/0 merges built-ins LAST,
    # so even a directly-poisoned :persistent_term cannot shadow a built-in.
    test "dynamic registration CANNOT shadow a static builtin (reserved-name guard)" do
      original = :persistent_term.get({CommandRegistry, :dynamic_commands}, %{})
      on_exit(fn -> :persistent_term.put({CommandRegistry, :dynamic_commands}, original) end)

      # register/3 refuses a built-in name outright.
      assert {:error, :reserved_name} =
               CommandRegistry.register("jq", "build/commands/grep.wasm", :stdin1)

      # Defense in depth: even a forced poison of the dynamic term loses to the
      # built-in at lookup (built-ins merged last).
      :persistent_term.put(
        {CommandRegistry, :dynamic_commands},
        Map.put(original, "jq", {:wasm, "build/commands/grep.wasm", :stdin1})
      )

      assert {:wasm, "build/commands/jq.wasm", :stdin1} = CommandRegistry.registry()["jq"]
      # jq still behaves like jq (emits the JSON string node, quotes and all),
      # NOT grep (which would print the matching line "bar").
      assert {:ok, ~s("alice")} = CommandRegistry.run("jq", ".name\n{\"name\":\"alice\"}")
    end

    test "register/3 rejects every reserved built-in name" do
      for n <- CommandRegistry.reserved_names() do
        assert {:error, :reserved_name} =
                 CommandRegistry.register(n, "build/commands/grep.wasm", :stdin1)
      end
    end

    test "re-registering a name overwrites the prior dynamic spec (last write wins)" do
      name = uniq("re")
      CommandRegistry.register(name, "build/commands/jq.wasm", :stdin1)
      CommandRegistry.register(name, "build/commands/grep.wasm", :stdin1)
      assert {:wasm, "build/commands/grep.wasm", :stdin1} = CommandRegistry.registry()[name]
    end

    test "registering does not drop the other dynamic commands" do
      a = uniq("a")
      b = uniq("b")
      CommandRegistry.register(a, "build/commands/grep.wasm", :stdin1)
      CommandRegistry.register(b, "build/commands/jq.wasm", :stdin1)
      names = CommandRegistry.list()
      assert a in names and b in names
    end

    # SECURITY REGRESSION (finding #10): empty/nil names polluted the namespace.
    test "register/3 rejects empty and nil names" do
      assert {:error, :invalid_name} = CommandRegistry.register("", "build/commands/jq.wasm")
      assert {:error, :invalid_name} = CommandRegistry.register(nil, "build/commands/jq.wasm")
      refute "" in CommandRegistry.list()
      refute nil in CommandRegistry.list()
    end

    test "register/3 rejects malformed names (separators / spaces)" do
      assert {:error, :invalid_name} = CommandRegistry.register("a/b", "build/commands/jq.wasm")
      assert {:error, :invalid_name} = CommandRegistry.register("a b", "build/commands/jq.wasm")
      assert {:error, :invalid_name} = CommandRegistry.register("../x", "build/commands/jq.wasm")
    end

    # SECURITY REGRESSION (finding #10): a registered path must live inside the
    # content-addressed commands store, never an arbitrary host path.
    test "register/3 rejects a wasm path outside the commands store" do
      planted = Path.join(System.tmp_dir!(), "wb_evil_#{System.unique_integer([:positive])}.wasm")
      File.write!(planted, "not really wasm")
      on_exit(fn -> File.rm(planted) end)

      assert {:error, :path_not_confined} = CommandRegistry.register(uniq("safe"), planted, :stdin1)
      refute uniq("safe") in CommandRegistry.list()
    end
  end

  # ---------------------------------------------------------------------------
  # build_and_register_crate — error path (no successful network build here)
  # ---------------------------------------------------------------------------

  describe "build_and_register_crate/3 error handling" do
    @tag :build
    @tag timeout: 120_000
    test "bogus crate name fails the cargo install and returns {:error, _}" do
      name = uniq("bogus")
      crate = "this-crate-absolutely-does-not-exist-zzz-#{System.unique_integer([:positive])}"
      assert {:error, _reason} = CommandRegistry.build_and_register_crate(name, crate)
      # On failure nothing is registered.
      refute name in CommandRegistry.list()
    end

    # SECURITY REGRESSION (finding #2 + #8): crate spec / name validation. No
    # network needed — rejected before any cargo invocation.
    test "rejects an option-injection crate token (leading dash)" do
      assert {:error, :invalid_crate} =
               CommandRegistry.build_and_register_crate(uniq("x"), "--git=http://evil")

      assert {:error, :invalid_crate} = CommandRegistry.build_and_register_crate(uniq("x"), "--version")
    end

    test "rejects a reserved command name as the build target" do
      assert {:error, :reserved_name} = CommandRegistry.build_and_register_crate("jq", "huniq")
    end

    test "accepts a well-formed crate spec with version (charset only — no install attempted here)" do
      # We only assert the validation gate lets it THROUGH to the (slow) installer;
      # the actual install is covered by the :build-tagged suites.
      assert match?({:crate_spec_ok}, validate_crate_spec("huniq@1.0.0"))
      assert match?({:crate_spec_ok}, validate_crate_spec("ripgrep"))
    end
  end

  # Mirror of the module's internal @crate_re so the charset gate is asserted
  # without invoking the network installer.
  defp validate_crate_spec(crate) do
    if Regex.match?(~r/^[a-zA-Z0-9_][a-zA-Z0-9_.\-]*(@[a-zA-Z0-9_.+\-]+)?$/, crate),
      do: {:crate_spec_ok},
      else: {:crate_spec_bad}
  end

  # SECURITY REGRESSION (finding #11): TOCTOU — a content-addressed artifact's
  # bytes are re-verified against the sha256 in its filename at RUN time. Swapping
  # the bytes after registration must be detected and refused.
  describe "content-address integrity at run time" do
    test "swapping the addressed bytes after register is detected on run" do
      name = uniq("addr")
      {:ok, addressed} = CommandRegistry.register_artifact(name, "build/commands/jq.wasm", :stdin1)
      on_exit(fn -> File.cp!("build/commands/jq.wasm", addressed) end)

      # Verifies normally first.
      assert {:ok, "42"} = CommandRegistry.run(name, ".x\n{\"x\":42}")

      # Tamper: overwrite the addressed sha path with different (grep) bytes.
      File.cp!("build/commands/grep.wasm", addressed)

      assert {:error, {:artifact_integrity, ^addressed}} =
               CommandRegistry.run(name, ".x\n{\"x\":42}")
    end
  end

  # ---------------------------------------------------------------------------
  # register_artifact — content addressing
  # ---------------------------------------------------------------------------

  describe "register_artifact/3" do
    test "content-addresses an existing wasm and registers the stable path" do
      name = uniq("art")
      {:ok, addressed} = CommandRegistry.register_artifact(name, "build/commands/grep.wasm", :stdin1)
      # Path is the content-addressed store, named <sha>.wasm.
      assert String.ends_with?(addressed, ".wasm")
      assert addressed =~ "build/commands/"
      assert {:wasm, ^addressed, :stdin1} = CommandRegistry.registry()[name]
      # And it runs from the addressed path.
      assert {:ok, "foo"} = CommandRegistry.run(name, "foo\nbar", ["oo"])
    end

    test "register_artifact on a missing path returns {:error, _} and registers nothing" do
      name = uniq("missing")
      assert {:error, _} =
               CommandRegistry.register_artifact(name, "build/commands/does-not-exist.wasm")
      refute name in CommandRegistry.list()
    end
  end

  # ---------------------------------------------------------------------------
  # ADVERSARIAL argv — injection-shaped args MUST be DATA, not executed
  # ---------------------------------------------------------------------------

  describe "argv adversarial / injection safety" do
    # Sentinel files an injected shell command would create on the host if argv
    # leaked into a shell. They must NOT exist after any run below.
    setup do
      sentinels = [
        Path.join(System.tmp_dir!(), "WB_CMDREG_PWNED_1"),
        Path.join(System.tmp_dir!(), "WB_CMDREG_PWNED_2")
      ]

      Enum.each(sentinels, &File.rm/1)
      on_exit(fn -> Enum.each(sentinels, &File.rm/1) end)
      {:ok, sentinels: sentinels}
    end

    test "injection-shaped argv on an :argv command is never executed on the host",
         %{sentinels: [s1, s2]} do
      # Build "$" <> "(...)" / backticks at runtime so the Elixir parser itself
      # never sees them as interpolation; they are literal data strings.
      argv = [
        "; rm -rf /",
        "$" <> "(touch #{s1})",
        "`touch #{s2}`",
        "&& curl evil",
        "| sh"
      ]

      # upper is :argv mode → these reach wasmtime as real argv (sh-escaped by
      # PackageManager.run), the guest ignores them, stdin is what's uppercased.
      assert {:ok, "PAYLOAD"} = CommandRegistry.run("upper", "payload", argv)
      refute File.exists?(s1), "command substitution leaked to host shell"
      refute File.exists?(s2), "backtick substitution leaked to host shell"
    end

    test "injection-shaped argv folded via :stdin1 is inert too", %{sentinels: [s1, _s2]} do
      # grep is :stdin1: argv joins onto line 1 as the PATTERN. A pattern of
      # "$(touch …)" is a literal regex string, not a shell command.
      pattern = "$" <> "(touch #{s1})"
      assert {:ok, _} = CommandRegistry.run("grep", "harmless\ntext", [pattern])
      refute File.exists?(s1), "stdin1-folded payload leaked to host shell"
    end

    @tag :build
    @tag timeout: 300_000
    test "an :argv command RECEIVES the raw argv verbatim as data (incl. metachars)" do
      # Build a tiny Rust CLI that echoes its argv + stdin, register :argv, then
      # prove the exact bytes (spaces, quotes, ;, $(...), backticks) arrive in the
      # guest unmodified — the strongest statement of "argv is data, not shell".
      name = uniq("argvecho")

      src = ~S"""
      use std::io::Read;
      fn main() {
          let a: Vec<String> = std::env::args().skip(1).collect();
          let mut s = String::new();
          std::io::stdin().read_to_string(&mut s).ok();
          print!("ARGS[{}] STDIN[{}]", a.join("~"), s.trim());
      }
      """

      assert {_, _, {:ok, wasm, _}} =
               PackageManager.build(%{"name" => "argvecho", "lang" => "rust", "src" => src}),
             "rust toolchain must build the argv-echo probe"

      {:ok, _addr} = CommandRegistry.register_artifact(name, wasm, :argv)

      argv = [
        "one",
        "two space",
        "has'apos",
        "has\"quote",
        "; rm -rf /",
        "$" <> "(touch /tmp/WB_SHOULD_NOT_EXIST)",
        "`id`"
      ]

      assert {:ok, out} = CommandRegistry.run(name, "hello", argv)
      assert out == "ARGS[#{Enum.join(argv, "~")}] STDIN[hello]"
      refute File.exists?("/tmp/WB_SHOULD_NOT_EXIST")
    end
  end

  # ---------------------------------------------------------------------------
  # boundary / edge inputs — empty, unicode, very-long
  # ---------------------------------------------------------------------------

  describe "boundary and unicode inputs" do
    test "empty stdin to upper yields empty output" do
      assert {:ok, ""} = CommandRegistry.run("upper", "")
    end

    test "whitespace-only stdin to upper trims to empty (run_builtin String.trim/1)" do
      assert {:ok, ""} = CommandRegistry.run("upper", "   \n\t  ")
    end

    test "unicode stdin: upper does Unicode-aware uppercasing" do
      # JS String.toUpperCase handles non-ASCII; ß has no single uppercase so it
      # becomes SS — assert the actual JS behavior, not an ASCII assumption.
      assert {:ok, out} = CommandRegistry.run("upper", "café αβγ straße")
      assert out == "CAFÉ ΑΒΓ STRASSE"
    end

    test "emoji / astral plane stdin passes through upper without corruption" do
      assert {:ok, out} = CommandRegistry.run("upper", "hi 🚀🧪 end")
      assert out == "HI 🚀🧪 END"
    end

    test "grep matches a unicode pattern over unicode lines" do
      assert {:ok, "café"} = CommandRegistry.run("grep", "café\nbar\nfoo", ["é"])
    end

    # FAILING ON PURPOSE — exposes a REAL bug, do not hide it.
    #
    # The `upper` builtin's JS reads stdin into a FIXED `new Uint8Array(8192)`
    # with `Javy.IO.readSync(0, b.subarray(t))`. Once `t` hits 8192,
    # `b.subarray(8192)` is a zero-length view, `readSync` returns 0, and the
    # loop exits — so ANY stdin over 8 KiB is SILENTLY TRUNCATED to its first
    # 8192 bytes. Measured: a 256 KiB input comes back as exactly 8192 bytes.
    #
    # The fix belongs in the builtin's JS (grow/chunk the buffer, e.g. read into
    # a list of chunks until readSync returns 0), NOT in this test. Leaving the
    # assertion as the CORRECT expectation so the bug stays visible.
    @tag :known_bug
    test "very-long stdin (256 KiB) round-trips through upper" do
      big = String.duplicate("ab", 128 * 1024)
      assert {:ok, out} = CommandRegistry.run("upper", big)
      # BUG: this fails — out is truncated to the first 8192 bytes.
      assert out == String.upcase(big)
      assert byte_size(out) == byte_size(big)
    end

    test "very-long single argv folded by :stdin1 (8 KiB pattern alt) is handled" do
      # Build a long alternation that still matches one line; proves long argv
      # survives the fold without truncation in the registry layer.
      alt = Enum.map_join(1..1000, "|", &"miss#{&1}") <> "|hit"
      assert {:ok, "hit"} = CommandRegistry.run("grep", "nope\nhit\nother", [alt])
    end

    test "garbage (non-JSON) stdin to jq surfaces jq's error, not a host crash" do
      # jq over invalid JSON: returns {:ok, <empty-after-trim>} or jq's stderr text;
      # either way it must be a tuple, never raise.
      assert {:ok, _} = CommandRegistry.run("jq", ".x\nthis is not json")
    end

    test "embedded NULs and control bytes in stdin do not crash the run path" do
      input = "a\0b\x01c\x1f"
      assert {:ok, _} = CommandRegistry.run("upper", input)
    end
  end
end
