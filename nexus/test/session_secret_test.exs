defmodule Nexus.Auth.SessionSecretTest do
  @moduledoc "Seam 1.1 / wb-nz88: strong_secret? gates the release boot-guard."
  use ExUnit.Case, async: false
  alias Nexus.Auth.Session

  test "missing / too-short secret is not strong; a >=16-byte secret is" do
    prev = System.get_env("WB_SESSION_SECRET")
    on_exit(fn -> if prev, do: System.put_env("WB_SESSION_SECRET", prev), else: System.delete_env("WB_SESSION_SECRET") end)

    System.delete_env("WB_SESSION_SECRET")
    refute Session.strong_secret?()

    System.put_env("WB_SESSION_SECRET", "short")
    refute Session.strong_secret?()

    System.put_env("WB_SESSION_SECRET", String.duplicate("x", 16))
    assert Session.strong_secret?()
  end
end
