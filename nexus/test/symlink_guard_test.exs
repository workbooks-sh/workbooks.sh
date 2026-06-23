defmodule Nexus.SymlinkGuardTest do
  @moduledoc "Seam 1.2 / wb-3t3c: the within_mount symlink-component walk rejects a planted symlink escape."
  use ExUnit.Case, async: true

  # mirrors server.work symlink_component?/2 — proves the algorithm catches a planted symlink
  defp symlink_component?(abs, root) do
    abs
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while(root, fn seg, cur ->
      p = Path.join(cur, seg)
      case File.lstat(p, []) do
        {:ok, %{type: :symlink}} -> {:halt, :symlink}
        _ -> {:cont, p}
      end
    end)
    |> Kernel.==(:symlink)
  end

  setup do
    base = Path.join(System.tmp_dir!(), "wb-symlink-#{System.unique_integer([:positive])}")
    mount = Path.join(base, "ws")
    outside = Path.join(base, "secret")
    File.mkdir_p!(Path.join(mount, "sub"))
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "k.txt"), "secret")
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base, mount: mount, outside: outside}
  end

  test "a path through a planted symlink is rejected", %{mount: mount, outside: outside} do
    link = Path.join(mount, "pwn")
    :ok = File.ln_s(outside, link)
    # /ws/pwn/k.txt expands lexically inside /ws, but pwn is a symlink to outside → must be caught
    abs = Path.expand(Path.join([mount, "pwn", "k.txt"]))
    assert symlink_component?(abs, Path.expand(mount))
  end

  test "a normal nested file is allowed", %{mount: mount} do
    File.write!(Path.join([mount, "sub", "ok.txt"]), "fine")
    abs = Path.expand(Path.join([mount, "sub", "ok.txt"]))
    refute symlink_component?(abs, Path.expand(mount))
  end

  test "a not-yet-existing file (new write) with no symlink ancestor is allowed", %{mount: mount} do
    abs = Path.expand(Path.join([mount, "sub", "new.txt"]))
    refute symlink_component?(abs, Path.expand(mount))
  end
end
