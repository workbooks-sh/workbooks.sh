defmodule Nexus.Wasmer do
  @moduledoc """
  The ONE wasm execution seam — run REAL programs on **Wasmer** (the mature WASIX/WASI runtime) over a
  host directory mounted at `/work`. This replaces our hand-rolled WebAssembly sandbox/shell (the bash
  emulation, the wasmtime CLI orchestration, the kit/VFS machinery). The division of labor is now clean:

    * **BEAM / Elixir** — orchestration, tenancy, data, and isolation (one OS process; supervised Elixir
      processes per run; the Store, control plane, sync). What the BEAM is best at.
    * **Wasmer** — wasm execution: a real POSIX-ish linux sandbox (WASIX: fork/exec/pipes/sockets/threads)
      with real filesystem access, plus 15+ language runtimes (python, quickjs, …) as registry packages.

  We invoke `wasmer` as a subprocess (one per run, watchdog-bounded), the same way we ran the wasmtime
  CLI — but Wasmer brings a whole mature ecosystem instead of code we maintain. The wasm guest is
  sandboxed to the mounted `/work` dir; that mount IS the trust boundary, exactly as before.
  """

  @guest "/work"
  @default_timeout_ms 30_000

  # PINNED registry packages (Phase 2 — don't float `latest` in prod). These exact versions are what the
  # image PRE-WARMS into the wasmer cache at build (dogfood/deploy/Dockerfile.base), so a cold/offline
  # Fly machine never round-trips the registry on first agent run. Bump deliberately, in lockstep with a
  # re-warm of the image. Overridable via `config :nexus, Nexus.Wasmer, bash_pkg:/python_pkg:`.
  @bash_pkg "sharrattj/bash@1.0.18"
  @python_pkg "wasmer/python@3.12.10-beta.2"

  @doc """
  The bash package to run. Prefers a LOCAL self-contained bundle (`bash_bundle/0`) — bash repackaged with
  NO registry dependency, so it runs **fully offline** (the prebuilt `sharrattj/bash` declares a
  `wasmer/coreutils` dep that resolution always re-fetches, which breaks airgapped machines). Falls back
  to the pinned registry package when no bundle is present. Overridable via config `:bash_pkg`.
  """
  def bash_pkg do
    case Keyword.get(Application.get_env(:nexus, __MODULE__, []), :bash_pkg) do
      nil -> bash_bundle() || @bash_pkg
      pkg -> pkg
    end
  end

  @doc """
  A LOCAL, dependency-free bash webc (true-offline, Phase 2 / #wb-hhhp). Returns a path, or nil if none is
  bundled and one can't be built. Resolution: config → known image path → cache → build-on-demand
  (download+unpack+strip the `[dependencies]`+repack; needs network ONCE, then cached for offline use).
  Pair with our self-contained coreutils (`coreutils/0`, already dep-free) via `--use`.
  """
  def bash_bundle do
    cache = Path.join(System.tmp_dir!(), "wb_bash_nodep.webc")

    first =
      Enum.find(
        [
          Keyword.get(Application.get_env(:nexus, __MODULE__, []), :bash_bundle),
          "/app/wasmer/bash.webc",
          Path.join(:code.priv_dir(:nexus), "wasmer/bash.webc"),
          cache
        ],
        fn p -> is_binary(p) and File.exists?(p) end
      )

    first || build_bash_bundle(cache)
  rescue
    _ -> nil
  end

  # Download the pinned bash, unpack it, STRIP its registry dependency, and repack as a self-contained
  # webc. Needs wasmer + network for the one-time download; cached after. Returns the path or nil.
  defp build_bash_bundle(out) do
    if available?() do
      dir = Path.join(System.tmp_dir!(), "wb_bashb_#{System.unique_integer([:positive])}")
      unp = Path.join(dir, "unpacked")
      dl = Path.join(dir, "bash.webc")
      File.mkdir_p!(dir)

      with {_, 0} <- System.cmd(bin(), ["package", "download", bash_bundle_src(), "-o", dl], stderr_to_stdout: true),
           {_, 0} <- System.cmd(bin(), ["package", "unpack", dl, "-o", unp, "--overwrite"], stderr_to_stdout: true),
           toml when is_binary(toml) <- File.exists?(Path.join(unp, "wasmer.toml")) && File.read!(Path.join(unp, "wasmer.toml")),
           stripped <- strip_dependencies(toml),
           :ok <- File.write(Path.join(unp, "wasmer.toml"), stripped),
           {_, 0} <- System.cmd(bin(), ["package", "build", unp, "-o", out], stderr_to_stdout: true) do
        File.rm_rf(dir)
        if File.exists?(out), do: out, else: nil
      else
        _ -> File.rm_rf(dir); nil
      end
    end
  rescue
    _ -> nil
  end

  defp bash_bundle_src, do: Keyword.get(Application.get_env(:nexus, __MODULE__, []), :bash_pkg, @bash_pkg)

  # Drop the `[dependencies] … = …` block from a wasmer.toml (the lines that make resolution phone home).
  defp strip_dependencies(toml) do
    toml
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {acc, in_deps?} ->
      t = String.trim(line)

      cond do
        t == "[dependencies]" -> {acc, true}
        in_deps? and String.starts_with?(t, "[") -> {[line | acc], false}
        in_deps? -> {acc, true}
        true -> {[line | acc], false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  @doc """
  The python package to run. Prefers a LOCAL webc (`python_bundle/0`) so it works offline — referencing
  python by registry NAME triggers a registry lookup that fails airgapped, but a local `.webc` runs
  directly (python has no problematic transitive dep, so unlike bash it needs no dep-stripping). Falls
  back to the pinned registry package. Overridable via config `:python_pkg`.
  """
  def python_pkg do
    case Keyword.get(Application.get_env(:nexus, __MODULE__, []), :python_pkg) do
      nil -> python_bundle() || @python_pkg
      pkg -> pkg
    end
  end

  @doc "A LOCAL python webc (true-offline). config → image path → cache → download-on-demand. nil if none."
  def python_bundle do
    cache = Path.join(System.tmp_dir!(), "wb_python.webc")

    Enum.find(
      [
        Keyword.get(Application.get_env(:nexus, __MODULE__, []), :python_bundle),
        "/app/wasmer/python.webc",
        Path.join(:code.priv_dir(:nexus), "wasmer/python.webc"),
        cache
      ],
      fn p -> is_binary(p) and File.exists?(p) end
    ) || download_python(cache)
  rescue
    _ -> nil
  end

  @doc """
  Build the self-contained offline bundles into `dir` (default `/app/wasmer`, the path `bash_bundle/0` +
  `python_bundle/0` check first). Called at IMAGE BUILD (network present) so a deployed machine runs the
  shell with NO registry access. coreutils needs no bundling here — `build_coreutils/1` packs the shipped
  `coreutils.wasm` with no deps at runtime (offline-safe). Returns `{bash_path | nil, python_path | nil}`.
  """
  def ensure_offline_bundles(dir \\ "/app/wasmer") do
    File.mkdir_p!(dir)
    bash = build_bash_bundle(Path.join(dir, "bash.webc"))
    python = download_python(Path.join(dir, "python.webc"))
    {bash, python}
  end

  defp download_python(out) do
    if available?() do
      src = Keyword.get(Application.get_env(:nexus, __MODULE__, []), :python_pkg, @python_pkg)

      case System.cmd(bin(), ["package", "download", src, "-o", out], stderr_to_stdout: true) do
        {_, 0} -> if File.exists?(out), do: out, else: nil
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  @doc "The wasmer binary: config `:wasmer_bin`, else `~/.wasmer/bin/wasmer`, else `wasmer` on PATH."
  def bin do
    cfg = Application.get_env(:nexus, __MODULE__, [])
    home = System.user_home()
    home_bin = home && Path.join(home, ".wasmer/bin/wasmer")

    cond do
      b = Keyword.get(cfg, :wasmer_bin) -> b
      is_binary(home_bin) and File.exists?(home_bin) -> home_bin
      b = System.find_executable("wasmer") -> b
      true -> "wasmer"
    end
  end

  @doc "Whether the Wasmer runtime is available."
  def available? do
    case System.cmd(bin(), ["--version"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Run `target` (a registry package like `"sharrattj/bash"` / `"wasmer/python"`, or a local `.wasm`/`.webc`
  path) with `args`, mounting `host_dir` at `/work`. Returns `{output, ok?}`. Wall-clock bounded.

  Opts: `:timeout_ms`, `:use` (a list of extra packages to expose on PATH, e.g. coreutils), `:net` (bool),
  `:command` (select one command from a multi-command package).
  """
  def run(target, args, host_dir, opts \\ []) when is_binary(target) and is_list(args) and is_binary(host_dir) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    # The Membrane socket bridge (opts[:membrane] = %{port, token}) needs the guest to reach the host
    # loopback (--net), the per-run port+token in the guest env, and the python shim mounted at /shim.
    mem = opts[:membrane]
    net? = opts[:net] || is_map(mem)

    flags =
      ["run", target]
      |> then(&(&1 ++ Enum.flat_map(Keyword.get(opts, :use, []), fn p -> ["--use", p] end)))
      |> then(&(if c = opts[:command], do: &1 ++ ["--command-name=#{c}"], else: &1))
      |> then(&(if net?, do: &1 ++ ["--net"], else: &1))
      |> then(&(if is_map(mem), do: &1 ++ membrane_flags(mem), else: &1))
      |> then(&(&1 ++ ["--volume", "#{host_dir}:#{@guest}"]))
      |> then(&(&1 ++ ["--"] ++ args))

    {raw, code} = bounded_cmd(bin(), flags, timeout)
    {sanitize(raw), code == 0}
  end

  defp membrane_flags(%{port: port, token: token}) do
    # --no-tty so the guest's stdin is a REAL pipe: with the default TTY bridge, the shim's
    # `sys.stdin.isatty()` returns true and it skips reading piped stdin (so `cat x | toolkit` sends no
    # data). Disabling the tty makes piped stdin flow into the shim correctly.
    ["--no-tty", "--env", "WB_MEMBRANE_PORT=#{port}", "--env", "WB_MEMBRANE_TOKEN=#{token}",
     "--volume", "#{Nexus.Membrane.shim_dir()}:/shim"]
  end

  @doc """
  Run a bash command `line` over `host_dir` (real bash + our full coreutils on PATH, cwd `/work`). The
  agent's shell. Returns `{output, ok?}`.
  """
  def bash(line, host_dir, opts \\ []) when is_binary(line) do
    # When the Membrane bridge is active, define the per-cap shim functions first so host caps compose
    # in pipes/chains (`cat x | work parse`).
    preamble = if is_map(opts[:membrane]), do: Nexus.Membrane.preamble() <> " ", else: ""
    run(bash_pkg(), ["-c", preamble <> "cd #{@guest} 2>/dev/null; " <> line], host_dir, Keyword.put_new(opts, :use, env()))
  end

  # All 74 uutils applets — packaged each as its own command so bash's exec sets argv[0]=<applet>, which
  # the multicall binary dispatches on. This fixes the prebuilt sharrattj/coreutils dispatch defect AND
  # is the anti-hijack list (a toolkit may not claim one of these). Defined before its first use.
  @coreutils_applets ~w(
    arch b2sum base32 base64 basename basenc cat cksum comm cp csplit cut date dd dir dircolors dirname
    echo expand factor false fmt fold head join link ln ls md5sum mkdir mktemp mv nl nproc numfmt od paste
    pathchk pr printenv printf ptx pwd readlink realpath rm rmdir seq sha1sum sha224sum sha256sum sha384sum
    sha512sum shred shuf sleep sort split sum tail tee touch tr true truncate tsort tty uname unexpand uniq
    unlink vdir wc yes)

  @doc """
  The agent's wasm-linux environment — the packages on bash's PATH: full coreutils, python, and any
  registered custom TOOLKITS (compiled wasm CLIs). So a toolkit works in a pipe (`cat x | rev`) just like
  a native command. nils (e.g. no toolkits) are dropped.
  """
  def env, do: Enum.reject([coreutils(), python_pkg(), toolkits()], &is_nil/1)

  @doc """
  A Wasmer package of all registered custom toolkits (each compiled wasm CLI as a command), so the agent's
  bash can exec them. Built on demand + cached keyed by the toolkit set; nil when there are none. This is
  how the Wasmer shell runs the SAME custom toolkits the old wasmtime-kit lane did.
  """
  def toolkits do
    kits =
      try do
        Nexus.Agent.Kits.all()
      rescue
        _ -> %{}
      end
      |> Enum.filter(fn {name, k} -> name != "coreutils" and is_binary(k[:wasm]) and File.exists?(k[:wasm]) end)
      |> Enum.sort_by(fn {name, _} -> name end)

    if kits == [], do: nil, else: build_toolkits(kits)
  end

  defp build_toolkits(kits) do
    key = :erlang.phash2(Enum.map(kits, fn {n, k} -> {n, k[:wasm], File.stat!(k[:wasm]).mtime} end))
    out = Path.join(System.tmp_dir!(), "wb_toolkits_#{key}.webc")

    if File.exists?(out) do
      out
    else
      dir = Path.join(System.tmp_dir!(), "wb_tk_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      mods =
        Enum.map_join(kits, "\n", fn {name, k} ->
          File.cp!(k[:wasm], Path.join(dir, "#{name}.wasm"))
          # Anti-hijack: a toolkit may NOT claim a coreutils applet name (would shadow the real one on
          # PATH). Host builtins (work/agent/web/…) are already intercepted before bash, so they're safe.
          commands = (k[:commands] || [name]) |> Enum.reject(&(&1 in @coreutils_applets))
          cmds = Enum.map_join(commands, "\n", &"[[command]]\nname = \"#{&1}\"\nmodule = \"#{name}\"\nrunner = \"https://webc.org/runner/wasi\"")
          "[[module]]\nname = \"#{name}\"\nsource = \"#{name}.wasm\"\nabi = \"wasi\"\n#{cmds}"
        end)

      File.write!(Path.join(dir, "wasmer.toml"), "[package]\nname = \"workbooks/toolkits\"\nversion = \"0.1.0\"\n#{mods}\n")
      {_o, code} = System.cmd(bin(), ["package", "build", dir, "-o", out], stderr_to_stdout: true)
      File.rm_rf(dir)
      if code == 0 and File.exists?(out), do: out, else: nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Our full coreutils package (all 74 uutils applets with correct argv[0] dispatch — fixes the prebuilt
  `sharrattj/coreutils` dispatch defect). Built ON DEMAND (cached) from the same `coreutils.wasm` the
  runtime already ships, so there's no committed binary. Falls back to the prebuilt if it can't be built.
  """
  def coreutils do
    cache = Path.join(System.tmp_dir!(), "wb_coreutils.webc")
    cond do
      File.exists?(cache) -> cache
      built = build_coreutils(cache) -> built
      true -> "sharrattj/coreutils"
    end
  rescue
    _ -> "sharrattj/coreutils"
  end

  defp build_coreutils(out) do
    wasm = coreutils_wasm()

    if wasm && File.exists?(wasm) and available?() do
      dir = Path.join(System.tmp_dir!(), "wb_cu_build_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.cp!(wasm, Path.join(dir, "coreutils.wasm"))

      cmds =
        Enum.map_join(@coreutils_applets, "\n", fn a ->
          "[[command]]\nname = \"#{a}\"\nmodule = \"coreutils\"\nrunner = \"https://webc.org/runner/wasi\""
        end)

      toml = """
      [package]
      name = "workbooks/coreutils"
      version = "0.1.0"
      [[module]]
      name = "coreutils"
      source = "coreutils.wasm"
      abi = "wasi"
      #{cmds}
      """

      File.write!(Path.join(dir, "wasmer.toml"), toml)
      File.rm(out)
      {_o, code} = System.cmd(bin(), ["package", "build", dir, "-o", out], stderr_to_stdout: true)
      File.rm_rf(dir)
      if code == 0 and File.exists?(out), do: out, else: nil
    end
  end

  # Locate the shipped coreutils.wasm (same binary the wasmtime kit lane uses).
  defp coreutils_wasm do
    [
      "/app/compilers/kits/coreutils.wasm",                          # deployed image (WORKDIR /app)
      Path.join(:code.priv_dir(:nexus), "wasmer/coreutils.wasm"),
      Path.join(File.cwd!(), "compilers/kits/coreutils.wasm"),
      Path.expand("kits/coreutils.wasm"),                            # dev (run from nexus/)
      Path.expand("../nexus/kits/coreutils.wasm")
    ]
    |> Enum.find(&File.exists?/1)
  rescue
    _ -> nil
  end

  @doc """
  Drop the prebuilt packages' teardown-crash noise so it never reaches the caller (output is correct
  by the time it fires; the fix is a clean package, tracked separately). Public so the long-lived
  `Nexus.Wasmer.Session` shares the exact same scrubbing.
  """
  def sanitize(raw) do
    raw
    |> String.split("\n")
    |> Enum.reject(fn l ->
      t = String.trim(l)
      String.contains?(l, "indirect call type mismatch") or String.starts_with?(t, "RuntimeError:") or
        String.contains?(l, "is deprecated and will be removed")
    end)
    |> Enum.join("\n")
  end

  @doc """
  Run a local `.wasm` toolkit standalone over `host_dir` with `stdin` piped in, returning `{output, ok?}`.
  This is the Membrane route-around for the WASIX bash-exec wall: a packaged EH/exnref toolkit loses its
  output when bash execs it in a pipe, but runs CLEAN standalone — so `cat x | toolkit` is served by
  running the toolkit HERE (host-side) with the piped bytes, via the socket bridge. System.cmd has no
  stdin, so stdin rides in through a temp file redirect.
  """
  def run_stdin(wasm, args, host_dir, stdin, opts \\ []) when is_binary(wasm) and is_binary(stdin) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    in_file = Path.join(System.tmp_dir!(), "wbstdin_#{System.unique_integer([:positive])}")
    File.write!(in_file, stdin)

    flags =
      ["run", wasm, "--volume", "#{host_dir}:#{@guest}", "--"] ++ args

    cmd = Enum.map_join([bin() | flags], " ", &shell_quote/1) <> " < " <> shell_quote(in_file)

    task = Task.async(fn -> System.cmd("/bin/sh", ["-c", cmd], stderr_to_stdout: true) end)

    {raw, code} =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {out, c}} -> {out, c}
        _ -> {"wasmer: killed", 137}
      end

    File.rm(in_file)
    {sanitize(raw), code == 0}
  end

  defp shell_quote(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  # System.cmd with a hard wall-clock kill — a hung guest can't hang the agent.
  defp bounded_cmd(bin, args, timeout_ms) do
    task = Task.async(fn -> System.cmd(bin, args, stderr_to_stdout: true) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, code}} -> {out, code}
      _ -> {"\nwasmer: killed (exceeded #{div(timeout_ms, 1000)}s budget)", 137}
    end
  end
end
