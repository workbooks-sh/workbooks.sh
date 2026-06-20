defmodule Nexus.Compilers.Swift do
  @moduledoc """
  The swift lane — Swift 6.2 ships an official **WebAssembly SDK** (WASI) and `swiftc` cross-compiles
  straight to a wasm core module (no intermediate C, unlike the zig lane).

  ## Honest trust note

  Unlike the rust/zig/c lanes, whose compilers run *inside* wasm (`mrustc.wasm`, `zig1.wasm`,
  `c4` in-sandbox) so untrusted source never touches a native compiler, Swift upstream ships only a
  **native** `swiftc` — there is no wasm-hosted Swift compiler yet (tracked: SwiftWasm BridgeJS /
  Component-Model work, 2026). So this lane invokes the provisioned native `swiftc` host-side to
  cross-compile to `wasm32-unknown-wasi`. The PRODUCED artifact is still a sandboxed wasm component
  (it runs on `Nexus.Sandbox` like every other lane); only the *compile step* is native. When a
  wasm-hosted swiftc lands upstream, swap `System.cmd("swiftc", …)` for the sandbox executor and this
  lane matches the others with no dispatcher change.

  The toolchain is provisioned into `compilers/swift/swift-root/` (gitignored, like every other lane —
  see `nexus/scripts/stage-tools.sh` + `compilers/swift/build.sh`):

      compilers/swift/swift-root/
        usr/bin/swiftc            # the native driver
        swift-wasi.sdk/           # the Swift SDK for WebAssembly (installed via `swift sdk install`)

  swift → wasm. Returns `{:ok, core_module_path}`.
  """

  @sdk_id "swift-wasm"

  @doc "Compile a swift source file to a wasm core module exporting `opts[:exports]`. `{:ok, path}`."
  def compile_to_wasm(source_path, opts \\ [], root \\ Nexus.Compilers.Shared.default_root()) do
    base = Path.expand(Path.join([root, "swift", "swift-root"]))
    swiftc = Path.join([base, "usr", "bin", "swiftc"])
    sdk = Path.join(base, "swift-wasi.sdk")

    id = "nx_#{System.unique_integer([:positive])}"
    job = Path.join(System.tmp_dir!(), id)
    File.mkdir_p!(job)
    src = Path.join(job, "src.swift")
    out = Path.join(job, "out.wasm")
    File.cp!(Path.expand(source_path), src)

    exports = Keyword.get(opts, :exports, [])
    export_flags = Enum.flat_map(exports, fn f -> ["-Xlinker", "--export=#{f}"] end)

    # Prefer the installed Swift SDK if present (resolves sysroot + stdlib); fall back to a raw
    # cross-target invocation against the bundled sdk path.
    sdk_args =
      if File.dir?(sdk),
        do: ["-swift-sdk", @sdk_id],
        else: ["-sdk", sdk]

    args =
      ["-target", "wasm32-unknown-wasi", "-O", "-static-stdlib", "-parse-as-library",
       "-Xclang-linker", "-mexec-model=reactor", "-o", out] ++
        sdk_args ++ export_flags ++ [src]

    result =
      case run(swiftc, args) do
        :ok ->
          if File.regular?(out) and File.stat!(out).size > 0,
            do: {:ok, persist(out, id)},
            else: {:error, :swift_compile_failed}

        {:error, _} = err ->
          err
      end

    File.rm_rf(job)
    result
  end

  defp run(swiftc, args) do
    bin = if File.regular?(swiftc), do: swiftc, else: "swiftc"

    case System.cmd(bin, args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:swift_compile_failed, code, out}}
    end
  rescue
    e -> {:error, {:swift_unavailable, Exception.message(e)}}
  end

  # Move the artifact out of the (about-to-be-reaped) job dir so the caller can componentize it.
  defp persist(out, id) do
    dest = Path.join(System.tmp_dir!(), "#{id}.core.wasm")
    File.cp!(out, dest)
    dest
  end
end
