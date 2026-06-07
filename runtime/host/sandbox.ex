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
  # Network-PERMITTED profile: only for the unavoidable dependency FETCH (e.g.
  # `cargo install <crate>` must reach crates.io). FS is still confined; this is
  # weaker than `run/2` and is used only where offline compile is impossible.
  @seatbelt_net "(version 1)(allow default)"

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

  This is the DEFAULT build isolator: network is DENIED. Use it for any compile
  whose dependencies are already present locally (vendored crate tree, a local
  source dir, an already-fetched node_modules) so a hostile build.rs / proc-macro
  / npm postinstall cannot exfiltrate or reach the host network.
  """
  def run([_ | _] = args, opts \\ []) do
    {cmd, cmd_args} = wrap(backend(), :deny_net, args)
    System.cmd(cmd, cmd_args, [stderr_to_stdout: true] ++ Keyword.take(opts, [:cd, :env]))
  end

  @doc """
  Run a command (arg list) FS-confined but with NETWORK PERMITTED — only for the
  unavoidable dependency-fetch step (e.g. `cargo install <crate>`, which must
  reach the registry before any local tree exists). This is a weaker guarantee
  than `run/2`: a fetched crate's build.rs still gets network. Prefer `run/2`
  (offline) whenever the deps can be vendored first. Returns `{output, status}`.
  """
  def run_net([_ | _] = args, opts \\ []) do
    {cmd, cmd_args} = wrap(backend(), :allow_net, args)
    System.cmd(cmd, cmd_args, [stderr_to_stdout: true] ++ Keyword.take(opts, [:cd, :env]))
  end

  # bwrap: fresh pid namespace, root read-only, /proc + /dev provided. A writable
  # build dir is added by the caller via --bind when wiring real builds. Net is
  # unshared only in the deny-net profile.
  defp wrap(:bwrap, net, args) do
    net_flag = if net == :deny_net, do: ["--unshare-net"], else: []
    {"bwrap", net_flag ++ ~w(--unshare-pid --new-session --die-with-parent --ro-bind / / --proc /proc --dev /dev --) ++ args}
  end

  defp wrap(:seatbelt, :deny_net, args), do: {"sandbox-exec", ["-p", @seatbelt | args]}
  defp wrap(:seatbelt, :allow_net, args), do: {"sandbox-exec", ["-p", @seatbelt_net | args]}
  defp wrap(:none, _net, [cmd | rest]), do: {cmd, rest}
end
