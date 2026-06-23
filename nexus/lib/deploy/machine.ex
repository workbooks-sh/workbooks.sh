defmodule Nexus.Deploy.Machine do
  @moduledoc """
  The local MACHINE — boots + runs the nexus runtime in a microVM on the user's box, OUTSIDE the
  engine (nexus's own wasmtime sandbox is a separate, inner boundary — don't conflate them).

  **vfkit, not krunvm.** We boot via **vfkit** (Apple Virtualization.framework) with a real
  `virtio-net,nat` NIC. The earlier krunvm path used libkrun **TSI** networking, which deadlocks the
  BEAM HTTP server inside the guest (the listener binds but never serves — bd wb-pqf4). vfkit gives
  the guest a real NIC + DHCP IP, so the nexus is reachable across the VM boundary like any host.

  The bootable artifact is the **engine-disk** (`ghcr.io/workbooks-sh/engine-disk:latest`): the SAME
  runtime image (`ghcr.io/workbooks-sh/runtime`) converted to a vfkit-bootable ext4 disk + Alpine
  kernel/initrd, published by CI (`.github/workflows/engine-disk.yml`). Its `init=/sbin/wb-init`
  DHCPs `eth0`, exports `WB_WEB=1 PORT=4000 WB_DATA=/data …`, and execs the release — it auto-serves
  on :4000 with no boot-expr. We share the host data dir into the guest at `/disco` (mountTag `disco`).

  Contract (unchanged shape): `preflight → ensure_engine_disk → create → spawn → await_ip →
  await_health → down`. The nexus URL is `http://<guestIP>:4000` (no 127.0.0.1 port-forward — vfkit
  NAT routes to the guest's own IP, discovered from the macOS DHCP lease DB by MAC).
  """
  @artifact_default "ghcr.io/workbooks-sh/engine-disk:latest"
  @guest_port 4000

  @doc false
  # The engine-disk ref to fetch/boot, resolved through the supply-chain trust seam: an operator's
  # allowlist/pin (Nexus.Config image-registries/image-pins) is enforced before we `oras pull` a rootfs
  # the VM boots. Neutral default ⇒ the canonical :latest ref unchanged (red-team wb-um2w/wb-b2ow).
  def artifact, do: Nexus.ArtifactTrust.resolve!(@artifact_default)
  @kernel_cmdline "console=hvc0 root=/dev/vda rw rootfstype=ext4 modules=ext4 init=/sbin/wb-init"

  # ── preflight ─────────────────────────────────────────────────────────────────────────────────

  @doc "Backend availability — vfkit (boot), oras (fetch the engine-disk), zstd (decompress)."
  def preflight do
    missing = Enum.reject(~w(vfkit oras zstd), &has?/1)

    cond do
      "vfkit" in missing -> {:error, :vfkit_missing, "vfkit not installed — `brew install vfkit`"}
      "oras" in missing -> {:error, :oras_missing, "oras not installed — `brew install oras`"}
      "zstd" in missing -> {:error, :zstd_missing, "zstd not installed — `brew install zstd`"}
      true -> :ok
    end
  end

  @doc """
  Fetch + decompress the engine-disk into a cached golden image (skips when present). `opts[:force]`
  re-pulls. `{:ok, golden_path} | {:error, _}`.
  """
  def ensure_engine_disk(opts \\ []) do
    File.mkdir_p!(engine_dir())
    golden = golden_disk()
    have = File.regular?(golden) and File.regular?(kernel_path()) and File.regular?(initrd_path())

    cond do
      opts[:force] -> pull_engine_disk()
      not have -> pull_engine_disk()
      # Re-pull when the published engine-disk has moved past our cached golden, so local runs the SAME
      # runtime as cloud (best-effort: if the registry is unreachable, keep the cached disk).
      drifted?() -> pull_engine_disk()
      true -> {:ok, golden}
    end
  end

  defp pull_engine_disk do
    # Clear the prior layers first so `oras pull` can't land a stale/partial blob alongside the new
    # descriptor (a caching race seen in testing). Forces a clean fetch of the current :latest.
    for f <- ~w(disk.img.zst disk.img kernel-image initramfs-wb), do: File.rm(Path.join(engine_dir(), f))

    with {:ok, _} <- sh_in(engine_dir(), "oras", ["pull", artifact()]),
         {:ok, _} <- sh_in(engine_dir(), "zstd", ["-d", "-f", "disk.img.zst", "-o", "disk.img"]) do
      _ = record_digest()
      {:ok, golden_disk()}
    else
      {:error, out} -> {:error, "engine-disk fetch failed: #{out}"}
      :error -> {:error, "oras/zstd not runnable"}
    end
  end

  # Has the remote engine-disk digest moved past the one we cached? nil/error → not drifted (offline-safe).
  defp drifted? do
    case remote_digest() do
      nil -> false
      remote -> remote != cached_digest()
    end
  end

  defp remote_digest do
    case sh("oras", ["manifest", "fetch", artifact(), "--descriptor"]) do
      {:ok, out} -> (Regex.run(~r/"digest"\s*:\s*"([^"]+)"/, out) || []) |> List.last()
      _ -> nil
    end
  end

  defp record_digest, do: with(d when is_binary(d) <- remote_digest(), do: File.write(digest_file(), d))
  defp cached_digest, do: case(File.read(digest_file()), do: ({:ok, d} -> String.trim(d); _ -> ""))
  defp digest_file, do: Path.join(engine_dir(), "digest")

  # ── create / boot ───────────────────────────────────────────────────────────────────────────

  @doc """
  Prepare a VM instance: clone the golden disk to a per-VM writeable copy (APFS clone when possible —
  near-free + keeps boots isolated), pick a fresh MAC, and persist the instance context. Returns
  `{:ok, %{mac, disk, data_dir, ctrl_port}}`. Idempotent: tears down any prior instance first.
  """
  def create(opts \\ []) do
    _ = down()
    data = Keyword.get(opts, :data_dir, default_data_dir())
    File.mkdir_p!(data)

    disk = instance_disk()
    File.rm_rf(disk)
    # `cp -c` = APFS copy-on-write clone (instant, no extra space) when on the same volume; falls back
    # to a full copy. The clone is mandatory: vfkit writes the root rw, so two boots must not share it.
    case sh("cp", ["-c", golden_disk(), disk]) do
      {:ok, _} -> :ok
      _ -> File.cp!(golden_disk(), disk)
    end

    vm = %{mac: stable_mac(), disk: disk, data_dir: data, ctrl_port: free_ctrl_port()}
    write_ctx(vm)
    {:ok, vm}
  end

  @doc """
  Boot the VM under vfkit, detached (nohup), writing the pid for `down`. vfkit needs no TTY (unlike
  krunvm). The guest's `wb-init` auto-serves the nexus on :4000 — no boot-expr. `{:ok, %{pid}}`.
  """
  def spawn_direct(vm \\ read_ctx()) do
    File.mkdir_p!(log_dir())
    write_secrets_env(vm.data_dir)
    argv = vfkit_argv(vm)
    cmd = argv |> Enum.map(&shquote/1) |> Enum.join(" ")
    out = Path.join(log_dir(), "runtime.out.log")
    err = Path.join(log_dir(), "runtime.err.log")
    script = "nohup #{cmd} >> #{shquote(out)} 2>> #{shquote(err)} & echo $! > #{shquote(pidfile())}"

    case sh("sh", ["-c", script]) do
      {:ok, _} -> {:ok, %{pid: read_pidfile(), agent: :vfkit}}
      {:error, m} -> {:error, m}
      :error -> {:error, "could not spawn vfkit"}
    end
  end

  # Deploy SECRETS to inject into the local guest, mirroring cloud's machine env (Provisioner.build_env)
  # so a secret-gated workbook (LLM/API key) runs the same locally as in cloud. We pass through genuine
  # deploy secrets the dev has in their host env (the legitimate deploy-injection seam) + anything under
  # the WB_SECRET_ prefix. Written to the /disco share as secrets.env (0600); wb-init sources it.
  @secret_keys ~w(OPENROUTER_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY BRAVE_API_KEY EXA_API_KEY
                  TAVILY_API_KEY WB_DATABASE_URL WB_S3_ACCESS_KEY_ID WB_S3_SECRET_ACCESS_KEY
                  WB_S3_ENDPOINT WB_S3_BUCKET WB_ENV_MASTER_KEY)

  defp write_secrets_env(data_dir) do
    File.mkdir_p!(data_dir)

    pairs =
      (@secret_keys ++ wb_secret_prefixed())
      |> Enum.uniq()
      |> Enum.flat_map(fn k -> case System.get_env(k), do: (nil -> []; "" -> []; v -> [{k, v}]) end)

    path = Path.join(data_dir, "secrets.env")

    if pairs == [] do
      File.rm(path)
    else
      body = Enum.map_join(pairs, "\n", fn {k, v} -> "#{k}=#{v}" end) <> "\n"
      File.write!(path, body)
      File.chmod(path, 0o600)
    end
  end

  defp wb_secret_prefixed, do: System.get_env() |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "WB_SECRET_"))

  @doc "The vfkit argv that boots `vm` (engine-disk root + virtio-net NAT + the host data share)."
  def vfkit_argv(vm) do
    [
      vfkit_bin(),
      # Match the CLOUD tier by default (1cpu/1024MB, from the deploy block via Nexus.Config) so a
      # local run doesn't mask OOM/concurrency a cloud machine would hit — faithful-tier testing.
      "--cpus", to_string(Nexus.Config.cpus()),
      "--memory", to_string(Nexus.Config.memory()),
      "--kernel", kernel_path(),
      "--initrd", initrd_path(),
      "--kernel-cmdline", @kernel_cmdline,
      "--device", "virtio-blk,path=#{vm.disk}",
      "--device", "virtio-net,nat,mac=#{vm.mac}",
      "--device", "virtio-rng",
      "--device", "virtio-fs,sharedDir=#{vm.data_dir},mountTag=disco",
      "--device", "virtio-serial,logFilePath=#{Path.join(log_dir(), "console.log")}",
      "--restful-uri", "tcp://127.0.0.1:#{vm.ctrl_port}"
    ]
  end

  # ── readiness ─────────────────────────────────────────────────────────────────────────────────

  @doc "Poll the macOS DHCP lease DB for the guest's IP by MAC, up to `timeout_s`. `{:ok, ip} | :error`."
  def await_ip(vm \\ read_ctx(), timeout_s \\ 30) do
    Enum.reduce_while(1..timeout_s, :error, fn _, _ ->
      case guest_ip(vm.mac) do
        nil -> Process.sleep(1000); {:cont, :error}
        ip -> {:halt, {:ok, ip}}
      end
    end)
  end

  @doc "Poll `http://ip:4000/health` for a 200 (any body), up to `timeout_s`. `:ok | :error`."
  def await_health(ip, timeout_s \\ 40) do
    url = "http://#{ip}:#{@guest_port}/health"

    Enum.reduce_while(1..timeout_s, :error, fn _, _ ->
      case sh("curl", ["-fsS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "3", url]) do
        {:ok, "200"} -> {:halt, :ok}
        _ -> Process.sleep(1000); {:cont, :error}
      end
    end)
  end

  @doc "The guest IP for `mac` from /var/db/dhcpd_leases, or nil. (hw_address has a `1,` type prefix.)"
  def guest_ip(mac) do
    case File.read("/var/db/dhcpd_leases") do
      {:ok, body} ->
        body
        |> String.split("{")
        |> Enum.find_value(fn block ->
          if String.contains?(block, mac), do: block_field(block, "ip_address="), else: nil
        end)

      _ ->
        nil
    end
  end

  # ── lifecycle ─────────────────────────────────────────────────────────────────────────────────

  @doc "Is a VM instance running (its vfkit pid alive)?"
  def exists? do
    case read_pidfile() do
      nil -> false
      pid -> match?({:ok, _}, sh("kill", ["-0", to_string(pid)]))
    end
  end

  @doc """
  Stop + remove the VM. vfkit ignores SIGTERM once the disk is open → SIGKILL the pid (after a best-
  effort graceful Stop via the restful control socket), then drop the per-VM disk clone + context.
  """
  def down do
    if vm = read_ctx() do
      _ = sh("curl", ["-fsS", "-X", "POST", "--max-time", "2", "http://127.0.0.1:#{vm.ctrl_port}/vm/state", "-d", ~s({"state":"Stop"})])
    end

    case read_pidfile() do
      nil -> :ok
      pid -> _ = sh("kill", ["-9", to_string(pid)]); :ok
    end

    File.rm(pidfile())
    File.rm(ctx_file())
    File.rm_rf(instance_disk())
    :ok
  end

  # ── internals ─────────────────────────────────────────────────────────────────────────────────

  defp engine_dir, do: support_dir("engine")
  defp golden_disk, do: Path.join(engine_dir(), "disk.img")
  defp kernel_path, do: Path.join(engine_dir(), "kernel-image")
  defp initrd_path, do: Path.join(engine_dir(), "initramfs-wb")
  defp instance_disk, do: support_dir("instance.disk.img")
  defp ctx_file, do: support_dir("instance.work")
  defp log_dir, do: support_dir("logs")
  defp pidfile, do: support_dir("runtime.pid")
  defp default_data_dir, do: support_dir("data")

  defp support_dir(leaf), do: Path.join([System.user_home!(), "Library", "Application Support", "sh.nexus", leaf])

  # Instance context as a `.work` block (blocks are the source of truth, not JSON — house mandate).
  defp write_ctx(vm) do
    File.mkdir_p!(Path.dirname(ctx_file()))
    body = """
    machine do
      mac="#{vm.mac}"
      disk="#{vm.disk}"
      data="#{vm.data_dir}"
      ctrl-port="#{vm.ctrl_port}"
    end
    """
    File.write!(ctx_file(), body)
  end

  defp read_ctx do
    case File.read(ctx_file()) do
      {:ok, body} ->
        %{
          mac: block_attr(body, "mac"),
          disk: block_attr(body, "disk"),
          data_dir: block_attr(body, "data"),
          ctrl_port: block_attr(body, "ctrl-port")
        }

      _ ->
        nil
    end
  end

  defp block_attr(body, key) do
    case Regex.run(~r/#{Regex.escape(key)}="([^"]*)"/, body) do
      [_, v] -> v
      _ -> nil
    end
  end

  defp block_field(block, key) do
    block
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(String.trim(line), key, parts: 2) do
        [_, v] when v != "" -> String.trim(v)
        _ -> nil
      end
    end)
  end

  # A STABLE per-box MAC (persisted on first use), so the NAT guest IP stays the same across boots —
  # the dev can bookmark `http://<ip>:4000`. Regenerate on demand by deleting the `mac` file.
  defp stable_mac do
    case File.read(mac_file()) do
      {:ok, m} when byte_size(m) >= 17 -> String.trim(m)
      _ -> m = gen_mac(); File.mkdir_p!(engine_dir()); File.write!(mac_file(), m); m
    end
  end

  defp mac_file, do: Path.join(engine_dir(), "mac")

  # A locally-administered, unicast MAC with every octet >= 0x11 — `/var/db/dhcpd_leases` strips
  # leading-zero nibbles, which would break the substring match, so we keep all octets two-nibble.
  defp gen_mac do
    [0x52 | for(_ <- 1..5, do: 0x11 + :rand.uniform(0xEE - 1))]
    |> Enum.map_join(":", &Integer.to_string(&1, 16))
    |> String.downcase()
  end

  # A control port unlikely to collide with the guest nexus (:4000) or a sibling VM.
  defp free_ctrl_port, do: 4200 + :rand.uniform(300)

  defp vfkit_bin, do: System.find_executable("vfkit") || "/opt/homebrew/bin/vfkit"
  defp has?(bin), do: System.find_executable(bin) != nil

  defp read_pidfile do
    with {:ok, s} <- File.read(pidfile()), {n, _} <- Integer.parse(String.trim(s)) do
      n
    else
      _ -> nil
    end
  end

  defp shquote(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  defp sh(cmd, args) do
    {out, code} = System.cmd(cmd, args, stderr_to_stdout: true)
    if code == 0, do: {:ok, String.trim(out)}, else: {:error, String.trim(out)}
  rescue
    ErlangError -> :error
  end

  defp sh_in(dir, cmd, args) do
    {out, code} = System.cmd(cmd, args, cd: dir, stderr_to_stdout: true)
    if code == 0, do: {:ok, String.trim(out)}, else: {:error, String.trim(out)}
  rescue
    ErlangError -> :error
  end
end
