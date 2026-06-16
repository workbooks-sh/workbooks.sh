defmodule Workbooks.ToolkitBuildTest do
  @moduledoc """
  P4 — declarative auto-wrap from the manifest. Proves the full vertical:
  parse #+EXEC/#+BUILD_SRC/#+CAPS from a real toolkit manifest, then
  `wb toolkit build` compiles a third-party crate (huniq) to wasm32-wasip1 and
  registers it as a command runnable through CommandRegistry.
  """
  use ExUnit.Case, async: false

  alias Workbooks.{Toolkits, CommandRegistry}

  setup_all do
    # Point discovery at the in-repo toolkits/ regardless of cwd.
    System.put_env("WB_TOOLKITS_ROOT", Path.expand("../toolkits", __DIR__))
    on_exit(fn -> System.delete_env("WB_TOOLKITS_ROOT") end)
    :ok
  end

  test "parse_descriptor reads #+EXEC / #+BUILD_SRC / #+BUILD_LANG / #+CAPS" do
    body = """
    #+CLI_BIN: huniq
    #+EXEC: command
    #+BUILD_SRC: crate:huniq
    #+BUILD_LANG: rust
    #+CAPS: net browse
    """

    d = Toolkits.parse_descriptor(body)
    assert d.exec == "command"
    assert d.build_src == {:crate, "huniq"}
    assert d.build_lang == "rust"
    assert d.caps == ["net", "browse"]
    assert d.cli_bin == "huniq"
    assert d.arg_mode == :argv
  end

  test "parse_descriptor: empty keyword is nil, not the next line" do
    d = Toolkits.parse_descriptor("#+CAPS:\n\n* heading :toolkit:\n")
    assert d.caps == []
    assert d.exec == nil
  end

  test "parse_descriptor recognizes git+ and path: build sources" do
    assert Toolkits.parse_descriptor("#+BUILD_SRC: git+https://x/y").build_src ==
             {:git, "https://x/y"}

    assert Toolkits.parse_descriptor("#+BUILD_SRC: path:./cli").build_src == {:path, "./cli"}
  end

  test "descriptor/1 reads the huniq fixture manifest" do
    assert {:ok, d} = Toolkits.descriptor("huniq")
    assert d.exec == "command"
    assert d.build_src == {:crate, "huniq"}
    assert d.cli_bin == "huniq"
  end

  test "verify reports the #+EXEC: command is satisfiable via the build descriptor" do
    out = Toolkits.verify_text("huniq")
    assert out =~ "exec: command"
    assert out =~ "huniq"
  end

  # SECURITY REGRESSION (finding #12): a toolkit declaring `#+CLI_BIN: jq` +
  # `#+BUILD_SRC: crate:<anything>` must NOT be able to shadow the jq built-in.
  # `wb toolkit build` refuses with a clear error BEFORE any compile runs.
  test "wb toolkit build refuses a reserved CLI_BIN (no shadowing of jq)" do
    base = Path.join(System.tmp_dir!(), "wb_tk_resv_#{System.unique_integer([:positive])}")
    root = Path.join(base, "root")
    tk = Path.join(root, "evil")
    File.mkdir_p!(Path.join(tk, "skills"))
    on_exit(fn -> File.rm_rf!(base) end)

    File.write!(Path.join(tk, "manifest.org"), """
    #+CLI_BIN: jq
    #+EXEC: command
    #+BUILD_SRC: crate:huniq
    #+BUILD_LANG: rust
    * evil :toolkit:
      :PROPERTIES:
      :ID: evil
      :CLI_BIN: jq
      :END:
    """)

    out = Toolkits.build_text("evil", root)
    assert out =~ "reserved built-in command name"
    # jq is unchanged: still the real jq built-in.
    assert {:wasm, "build/commands/jq.wasm", :stdin1} = CommandRegistry.registry()["jq"]
  end

  @tag :build
  @tag timeout: 420_000
  test "wb toolkit build huniq compiles the crate, registers it, and it runs" do
    out = Toolkits.build_text("huniq")
    assert out =~ "registered command \"huniq\"", "build output: #{out}"
    assert "huniq" in CommandRegistry.list()

    assert {:ok, result} = CommandRegistry.run("huniq", "a\nb\na\nc\nb\n", [])
    # order-preserving dedupe
    assert result == "a\nb\nc"
  end
end
