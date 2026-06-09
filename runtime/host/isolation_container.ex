defmodule Workbooks.IsolationContainer do
  @moduledoc """
  The `:container` isolation tier (wb-kt6) — run a command's wasm in a THROWAWAY
  container: kernel-level isolation + hard resource limits, the hostile / untrusted
  multi-tenant boundary. Heaviest tier (a container spawn per call).

  The command's content-addressed `.wasm` is mounted read-only into a minimal Linux
  wasmtime image and run with `--network none`, a memory/CPU/pids ceiling, and a
  read-only rootfs. stdin is mounted (not piped) to avoid shell plumbing; stdout is
  captured. The image is configurable (`WB_CONTAINER_IMAGE`, default
  `wb-wasmtime:latest`; build it from runtime/deploy/container-tier) and the runtime
  too (`WB_CONTAINER_RUNTIME`, default `docker` — podman/krunvm are drop-in).
  """

  @default_image "wb-wasmtime:latest"

  @doc """
  Run a registered command in a container. Same contract as CommandRegistry.run/3.
  `{:ok, stdout}` | `{:error, reason}`. Only content-addressed `:wasm` commands run
  here (builtins/src don't); falls to `{:error, {:container_unsupported_command, _}}`.
  """
  def run(command, input, argv \\ []) do
    with {:ok, path, mode} <- resolve(command),
         true <- available?() do
      do_run(path, mode, input, argv)
    else
      false -> {:error, :container_tier_unavailable}
      {:error, _} = err -> err
    end
  end

  @doc "Is the container tier usable here (runtime present + image built)?"
  def available? do
    rt = runtime()
    image = image()

    case System.cmd(rt, ["image", "inspect", image], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # ── internals ───────────────────────────────────────────────────────────────

  defp resolve(command) do
    case Workbooks.CommandRegistry.current(command) do
      {:wasm, path, mode} -> {:ok, path, mode}
      {:wasm, path, mode, _opts} -> {:ok, path, mode}
      _ -> {:error, {:container_unsupported_command, command}}
    end
  end

  defp do_run(path, mode, input, argv) do
    {stdin, wargv} = apply_mode(mode, input, argv)
    tmp = Path.join(System.tmp_dir!(), "wbc-stdin-#{:erlang.unique_integer([:positive])}")
    File.write!(tmp, stdin)

    inner = "wasmtime run /cmd.wasm " <> Enum.map_join(wargv, " ", &esc/1) <> " < /work/stdin"

    args =
      [
        "run", "--rm",
        "--network", "none",
        "--memory", "256m", "--cpus", "1", "--pids-limit", "128",
        "--read-only",
        # writable scratch for wasmtime's cache (rootfs stays read-only)
        "--tmpfs", "/root/.cache:rw,size=16m", "--tmpfs", "/tmp:rw,size=16m",
        "-v", "#{Path.expand(path)}:/cmd.wasm:ro",
        "-v", "#{tmp}:/work/stdin:ro",
        "--entrypoint", "/bin/sh",
        image(),
        "-c", inner
      ]

    try do
      case System.cmd(runtime(), args, stderr_to_stdout: false) do
        {out, 0} -> {:ok, out}
        {out, code} -> {:error, {:container_exit, code, out}}
      end
    after
      File.rm(tmp)
    end
  end

  # Mirror CommandRegistry's arg modes: :argv passes real argv; :stdin1 folds argv
  # into the first stdin line (the legacy jq/grep protocol).
  defp apply_mode(:stdin1, input, argv), do: {Enum.join(argv, " ") <> "\n" <> input, []}
  defp apply_mode(_argv, input, argv), do: {input, argv}

  defp esc(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  defp runtime, do: System.get_env("WB_CONTAINER_RUNTIME") || "docker"
  defp image, do: System.get_env("WB_CONTAINER_IMAGE") || @default_image
end
