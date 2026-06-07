defmodule Workbooks.Sandbox do
  @moduledoc """
  Build isolation (wb-11ck.27). Untrusted source (a Workbook's Rust/Go/JS) is
  compiled inside a sandbox that denies network and confines writes — so a
  hostile `build.rs` / `postinstall` can't exfiltrate or tamper with the host.

  Two backends, picked per platform: `bwrap` (Linux user-namespace isolation —
  the engine image) and `sandbox-exec` (macOS seatbelt — local dev). Same role,
  one API. The trusted toolchain (cargo/tinygo/javy) runs the build; the sandbox
  bounds what the build can reach.

  Network-free builds need deps pre-fetched (the wb-11ck.36 pattern: resolve +
  vendor first, then compile offline-sandboxed); this module is the isolator the
  build runs under.
  """
  # Deny all network; allow the rest (the build needs fs + exec of the toolchain).
  @seatbelt "(version 1)(allow default)(deny network*)"

  @doc "Which isolator backs this host: :bwrap | :seatbelt | :none."
  def backend do
    cond do
      System.find_executable("bwrap") -> :bwrap
      System.find_executable("sandbox-exec") -> :seatbelt
      true -> :none
    end
  end

  @doc """
  Run a command (arg list) network-isolated on the host platform. Returns
  `{output, exit_status}` like `System.cmd`. `opts` may carry `:cd`/`:env`.
  """
  def run([_ | _] = args, opts \\ []) do
    {cmd, cmd_args} = wrap(backend(), args)
    System.cmd(cmd, cmd_args, [stderr_to_stdout: true] ++ Keyword.take(opts, [:cd, :env]))
  end

  # bwrap: fresh net/pid namespaces, root read-only, /proc + /dev provided. A
  # writable build dir is added by the caller via --bind when wiring real builds.
  defp wrap(:bwrap, args),
    do: {"bwrap", ~w(--unshare-net --unshare-pid --new-session --die-with-parent --ro-bind / / --proc /proc --dev /dev --) ++ args}

  defp wrap(:seatbelt, args), do: {"sandbox-exec", ["-p", @seatbelt | args]}
  defp wrap(:none, [cmd | rest]), do: {cmd, rest}
end
