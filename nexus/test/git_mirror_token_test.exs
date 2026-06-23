defmodule Nexus.GitMirrorTokenTest do
  @moduledoc "Seam 0.2 / wb-7a2s: a mirror token must never be persisted in the bare repo's git config."
  use ExUnit.Case, async: true

  setup do
    base = Path.join(System.tmp_dir!(), "wb-mirror-#{System.unique_integer([:positive])}")
    bare = Path.join(base, "repo.git")
    File.mkdir_p!(bare)
    {_, 0} = System.cmd("git", ["init", "--bare", bare], stderr_to_stdout: true)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, bare: bare}
  end

  defp config(bare) do
    case System.cmd("git", ["--git-dir=#{bare}", "config", "--get", "workbooks.mirror"], stderr_to_stdout: true) do
      {v, 0} -> String.trim(v)
      _ -> nil
    end
  end

  test "a tokenized mirror URL is stored WITHOUT the token", %{bare: bare} do
    :ok = Nexus.Git.set_mirror(bare, "https://x-access-token:ghs_SUPERSECRETTOKEN@github.com/acme/site.git")
    stored = config(bare)

    refute stored =~ "ghs_SUPERSECRETTOKEN"
    refute stored =~ "x-access-token"
    assert stored == "https://github.com/acme/site.git"
  end

  test "a credential-free URL is stored as-is", %{bare: bare} do
    :ok = Nexus.Git.set_mirror(bare, "https://github.com/acme/site.git")
    assert config(bare) == "https://github.com/acme/site.git"
  end

  test "clearing the mirror removes the config", %{bare: bare} do
    :ok = Nexus.Git.set_mirror(bare, "https://github.com/acme/site.git")
    :ok = Nexus.Git.set_mirror(bare, "")
    assert config(bare) == nil
  end
end
