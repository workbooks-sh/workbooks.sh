defmodule Nexus.DeployTest do
  use ExUnit.Case, async: true

  test "status reports the local target" do
    assert %{target: :local, running: r} = Nexus.Deploy.status()
    assert is_boolean(r)
  end

  test "local/2 degrades gracefully when krunvm is absent (no crash)" do
    # In CI/dev krunvm usually isn't installed — preflight returns a clear error, not an exception.
    assert {:error, _} = Nexus.Deploy.local("nexus:latest")
  end

  test "the boot argv runs the nexus release binary, not the runtime's" do
    argv = Nexus.Deploy.Machine.start_argv(%{})
    assert "/app/bin/nexus" in argv
    assert "eval" in argv
  end
end
