defmodule Nexus.GeneratorTest do
  use ExUnit.Case, async: false

  setup do
    vfs = Nexus.Agent.Vfs.new()
    on_exit(fn -> Nexus.Agent.Vfs.destroy(vfs) end)
    {:ok, vfs: vfs}
  end

  # ---- asset store round-trip (no network) ----

  test "Nexus.Assets persists bytes and serves them back with a /assets URL + content type" do
    {:ok, a} = Nexus.Assets.put("t_test", <<137, 80, 78, 71>>, "image/png")
    assert a.url =~ ~r{^/assets/t_test/.+\.png$}
    assert a.content_type == "image/png"
    assert {:ok, <<137, 80, 78, 71>>, "image/png"} = Nexus.Assets.read("t_test", a.name)
    # path traversal in the name can't escape the tenant dir
    assert :error = Nexus.Assets.read("t_test", "../../etc/passwd")
    File.rm_rf(Nexus.Assets.dir("t_test"))
  end

  # ---- bash gating: a generator command runs ONLY when its capability is active ----

  test "image/video/speak are refused unless the matching generator capability is active", %{vfs: vfs} do
    inactive = %{tools: nil, grant: [], caps: [], tenant: "t_test"}
    assert Nexus.Agent.Bash.run(vfs, "image a calico cat", inactive) =~ "isn't active"
    assert Nexus.Agent.Bash.run(vfs, "speak hello there", inactive) =~ "isn't active"
  end

  test "an active generator capability reaches the generator (fails cleanly without CF creds)", %{vfs: vfs} do
    active = %{tools: nil, grant: [], caps: ["image-generation"], tenant: "t_test"}
    out = Nexus.Agent.Bash.run(vfs, "image a calico cat", active)
    refute out =~ "isn't active"
    # No CLOUDFLARE_* secrets in test → it got past the gate and into Nexus.Generator, which reports
    # the missing config rather than silently doing nothing.
    assert out =~ "generation failed"
    assert out =~ "Cloudflare"
  end

  test "the `generate` kit is listed so the agent can discover image/video/speak", %{vfs: vfs} do
    assert Nexus.Agent.Bash.run(vfs, "kits") =~ "generate"
    assert Nexus.Agent.Bash.run(vfs, "help generate") =~ "image"
  end
end
