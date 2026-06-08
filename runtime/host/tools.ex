defmodule Workbooks.Tools do
  @moduledoc """
  Provision + verify the pinned WASM toolchain the build path shells out to: javy
  (JS→wasm), wasm-tools (component new/validate), wac (compose/plug), and the wasi
  command adapter. The single source of truth is scripts/provision-tools.sh +
  scripts/tools.lock (pinned versions, sha256 per platform asset).

  `ensure!/0` is the lazy chokepoint: the first build that needs a tool provisions the
  whole set if anything is missing, then memoizes success so later builds pay nothing.
  This is why a fresh checkout / worktree / CI box "just works" instead of failing with
  a cryptic `execvp() of '.../javy' failed: No such file or directory`.
  """
  @tools Path.expand(Path.join([__DIR__, "..", "build", "tools"]))
  @script Path.expand(Path.join([__DIR__, "..", "scripts", "provision-tools.sh"]))
  @required ~w(javy wasm-tools wac wasi_snapshot_preview1.command.wasm)
  @flag {__MODULE__, :provisioned}

  @doc "Directory the tools live in."
  def tools_dir, do: @tools

  @doc "Pinned tools that are NOT yet present."
  def missing, do: Enum.reject(@required, &File.exists?(Path.join(@tools, &1)))

  @doc """
  Ensure every pinned tool is present, running the provisioner if any is missing.
  Returns :ok | {:error, reason}. Memoized after first success (per VM).
  """
  def ensure do
    if :persistent_term.get(@flag, false) do
      :ok
    else
      case missing() do
        [] ->
          :persistent_term.put(@flag, true)
          :ok

        want ->
          case System.cmd("bash", [@script], stderr_to_stdout: true) do
            {_, 0} ->
              case missing() do
                [] -> :persistent_term.put(@flag, true); :ok
                still -> {:error, {:still_missing, still}}
              end

            {out, code} ->
              {:error, {:provision_failed, code, String.slice(to_string(out), -800..-1//1), want}}
          end
      end
    end
  end

  @node_dir Path.expand(Path.join([__DIR__, "..", "node_modules", ".bin"]))

  @doc """
  Ensure jco/componentize-js are installed (node_modules/.bin/jco) — npm packages run via
  node, provisioned by `bun install` (or npm) in runtime/. Self-heals the JS typed-component
  (jco) lane like `ensure/0` self-heals the binary tools. Returns :ok | {:error, _}.
  """
  def ensure_jco do
    if File.exists?(Path.join(@node_dir, "jco")) do
      :ok
    else
      rt = Path.expand(Path.join(__DIR__, ".."))

      installer =
        cond do
          System.find_executable("bun") -> ["bun", "install"]
          System.find_executable("npm") -> ["npm", "install"]
          true -> nil
        end

      if installer == nil do
        {:error, :no_bun_or_npm}
      else
        case System.cmd(hd(installer), tl(installer), cd: rt, stderr_to_stdout: true) do
          {_, 0} -> if File.exists?(Path.join(@node_dir, "jco")), do: :ok, else: {:error, :jco_still_missing}
          {out, code} -> {:error, {:install_failed, code, String.slice(to_string(out), -400..-1//1)}}
        end
      end
    end
  end

  @doc "Ensure jco or raise with an actionable message."
  def ensure_jco! do
    case ensure_jco() do
      :ok -> :ok
      {:error, reason} -> raise "jco not provisioned (#{inspect(reason)}). Run: cd runtime && bun install"
    end
  end

  @doc "Like `ensure/0` but raises with an actionable message."
  def ensure! do
    case ensure() do
      :ok ->
        :ok

      {:error, reason} ->
        raise """
        WASM toolchain not provisioned (#{inspect(reason)}).
        Run:  bash scripts/provision-tools.sh
        (pins: scripts/tools.lock)
        """
    end
  end
end
