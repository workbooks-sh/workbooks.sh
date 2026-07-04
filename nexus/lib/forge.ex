defmodule Nexus.Forge do
  @moduledoc """
  Local micro-VM **compute terminals** — the agent's failsafe for builds the WASM sandbox can't host
  (native toolchains, Linux-only binaries, heavy compiles). A terminal is a throwaway Linux micro-VM the
  agent opens, runs commands in, and closes.

  **LOCAL-ONLY by design** (`Nexus.Config.forge_enabled?`): off unless `WB_FORGE=1`, and hard-false on a
  deployed nexus — a cloud machine can never open a nested micro-VM. This is a power tool for the TRUSTED
  local agent, NOT another untrusted sandbox (that stays the WASM path).

  **Backend: Lima on `vz`** (Apple Virtualization.framework / HVF) — the mac-native hypervisor, giving SSH
  exec + file-sharing for free, with no krunvm/libkrun-TSI deadlock (the reason `Nexus.Deploy.Machine`
  moved off krunvm; bd wb-pqf4). Hypervisor-agnostic: `vz` on mac, QEMU/krunkit elsewhere. See
  `nexus/docs/micro-vms.md`.

      {:ok, t} = Nexus.Forge.open()
      {:ok, %{out: out, exit: 0}} = Nexus.Forge.run(t, "uname -a && cc --version")
      :ok = Nexus.Forge.close(t)
  """
  require Logger

  @default_template "template://alpine"

  @doc """
  Open a micro-VM compute terminal. `opts`: `:template` (Lima template, default alpine — smallest/fastest),
  `:cpus` (2), `:memory_gib` (2), `:name`. Returns `{:ok, %{name: name}}` or `{:error, reason}`. Blocks
  while the VM boots (first boot also downloads the base image).
  """
  def open(opts \\ []) do
    cond do
      not Nexus.Config.forge_enabled?() -> {:error, :forge_disabled}
      lima() == nil -> {:error, :lima_missing}
      true -> do_open(opts)
    end
  end

  defp do_open(opts) do
    name = "forge-" <> (opts[:name] || rand_id())

    args = [
      "start",
      "--name=#{name}",
      "--vm-type=vz",
      "--cpus=#{opts[:cpus] || 2}",
      "--memory=#{opts[:memory_gib] || 2}",
      "--tty=false",
      opts[:template] || @default_template
    ]

    case System.cmd(lima(), args, stderr_to_stdout: true) do
      {_out, 0} ->
        Logger.info("forge: opened #{name}")
        {:ok, %{name: name}}

      {out, code} ->
        {:error, {:start_failed, code, tail(out)}}
    end
  end

  @doc """
  Run a shell command inside the terminal (login shell, so PATH/build tools resolve). Returns
  `{:ok, %{out: combined_stdout_stderr, exit: code}}` — a non-zero `exit` is a valid result, not an error;
  `{:error, _}` is reserved for the VM being unreachable.
  """
  def run(%{name: name}, cmd) when is_binary(cmd) do
    case System.cmd(lima(), ["shell", name, "--", "sh", "-lc", cmd], stderr_to_stdout: true) do
      {out, code} -> {:ok, %{out: out, exit: code}}
    end
  rescue
    e -> {:error, {:run_failed, Exception.message(e)}}
  end

  @doc "Copy a host file into the terminal (build inputs)."
  def put(%{name: name}, host_path, guest_path) do
    case System.cmd(lima(), ["copy", host_path, "#{name}:#{guest_path}"], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:copy_failed, code, tail(out)}}
    end
  end

  @doc "Copy a file out of the terminal (build artifacts)."
  def get(%{name: name}, guest_path, host_path) do
    case System.cmd(lima(), ["copy", "#{name}:#{guest_path}", host_path], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:copy_failed, code, tail(out)}}
    end
  end

  @doc "Stop + delete the terminal's micro-VM (reclaim all state)."
  def close(%{name: name}) do
    _ = System.cmd(lima(), ["stop", "-f", name], stderr_to_stdout: true)
    _ = System.cmd(lima(), ["delete", "-f", name], stderr_to_stdout: true)
    :ok
  end

  @doc "The Forge terminals that currently exist (name + status)."
  def list do
    if lima() == nil do
      []
    else
      case System.cmd(lima(), ["list", "--format", "{{.Name}}\t{{.Status}}"], stderr_to_stdout: true) do
        {out, 0} ->
          out
          |> String.split("\n", trim: true)
          |> Enum.filter(&String.starts_with?(&1, "forge-"))
          |> Enum.map(fn line ->
            case String.split(line, "\t", parts: 2) do
              [n, s] -> %{name: n, status: s}
              [n] -> %{name: n, status: "?"}
            end
          end)

        _ ->
          []
      end
    end
  end

  @doc "Whether the Forge is usable here (enabled + Lima present)."
  def available?, do: Nexus.Config.forge_enabled?() and lima() != nil

  defp lima, do: System.find_executable("limactl")
  defp rand_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  defp tail(s), do: String.slice(s, max(0, String.length(s) - 400), 400)
end
