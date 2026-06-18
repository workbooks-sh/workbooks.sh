defmodule WorkCLI.ContextTest do
  use ExUnit.Case, async: false
  alias WorkCLI.Context

  setup do
    dir = Path.join(System.tmp_dir!(), "ctx_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Application.put_env(:work_cli, :context_file, Path.join(dir, "context.html"))
    on_exit(fn -> Application.delete_env(:work_cli, :context_file); File.rm_rf(dir) end)
    :ok
  end

  test "set upserts + activates a target; use switches; load round-trips through HTML" do
    Context.set("local", %{"nexus" => "http://localhost:4000"})
    Context.set("cloud", %{"nexus" => "https://api.workbooks.sh", "org" => "acme", "workspace" => "main"})

    ctx = Context.load()
    assert ctx.active == "cloud"
    assert ctx.targets["cloud"]["org"] == "acme"
    assert ctx.targets["local"]["nexus"] == "http://localhost:4000"

    # the file is on-canon HTML, not JSON
    html = File.read!(Application.get_env(:work_cli, :context_file))
    assert html =~ ~s(<work-context active="cloud">)
    assert html =~ ~s(<work-target name="cloud")

    assert Context.use("local") == :ok
    assert Context.load().active == "local"
    assert Context.use("nope") == {:error, :unknown}
  end

  test "nexus_url resolves the active target, WB_RUNTIME_URL overrides" do
    Context.set("local", %{"nexus" => "http://host:4000"})
    assert Context.nexus_url() == "http://host:4000"

    System.put_env("WB_RUNTIME_URL", "http://override:9000")
    assert Context.nexus_url() == "http://override:9000"
    System.delete_env("WB_RUNTIME_URL")
  end
end
