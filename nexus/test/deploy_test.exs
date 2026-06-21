defmodule Nexus.DeployTest do
  use ExUnit.Case, async: true
  alias Nexus.Deploy.Machine

  test "status reports the local target" do
    assert %{target: :local, running: r} = Nexus.Deploy.status()
    assert is_boolean(r)
  end

  test "preflight checks the vfkit toolchain without crashing" do
    # :ok when vfkit/oras/zstd are present, else a clear {:error, reason, hint} — never an exception.
    assert Machine.preflight() == :ok or match?({:error, _, _}, Machine.preflight())
  end

  test "vfkit_argv boots the engine-disk with a real virtio-net NIC + the data share" do
    vm = %{mac: "52:11:22:33:44:55", disk: "/tmp/d.img", data_dir: "/tmp/data", ctrl_port: 4242}
    argv = Machine.vfkit_argv(vm)

    assert "--kernel" in argv and "--initrd" in argv
    # the fix: a real NAT NIC (not krunvm/libkrun TSI), the cloned per-VM root, the host data share
    assert Enum.any?(argv, &String.contains?(&1, "virtio-net,nat,mac=52:11:22:33:44:55"))
    assert Enum.any?(argv, &String.contains?(&1, "virtio-blk,path=/tmp/d.img"))
    assert Enum.any?(argv, &String.contains?(&1, "sharedDir=/tmp/data,mountTag=disco"))
    assert Enum.any?(argv, &String.contains?(&1, "init=/sbin/wb-init"))
  end

  test "guest_ip returns nil for a MAC with no DHCP lease" do
    assert Machine.guest_ip("fe:ee:dd:cc:bb:aa") == nil
  end
end
