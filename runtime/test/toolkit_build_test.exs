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
    # discover_dir/parse_headlines route through the OQL kernel process.
    case Workbooks.OQL.start_link(nil) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

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
