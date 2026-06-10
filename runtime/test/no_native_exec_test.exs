defmodule Workbooks.NoNativeExecTest do
  @moduledoc """
  wb-9ja — the no-native-execution invariant. After the purge it must be
  IMPOSSIBLE for the in-sandbox agent to run native code, and compilation must go
  through the wasm lanes only (never a native-compiler fallback).

  Three guards:
    (a) the agent's tool surface — base AND exec — exposes NO tool that execs
        native code (specifically: no "run" tool).
    (b) Workbooks.Sandbox (the native bwrap/seatbelt exec wrapper) is GONE.
    (c) the compile entry points return a lane-unavailable error (not a native
        call) when the native fallback is requested.

  SUBSTRATE NOTE: `wasmtime` running a `.wasm` IS the architecture and stays — the
  ban is on NATIVE language toolchains (cargo/rustc/zig/go/bun/npm) and any agent
  path to run an arbitrary native command line.
  """
  use ExUnit.Case, async: true

  # ── (a) the agent tool surface has no native-exec tool ──────────────────────
  # tools/1 is private; the agent exposes a test-only window onto the names the
  # model would see for a default run and an exec (trusted) run.
  defp tool_names(opts), do: Workbooks.Agent.__tool_names_for_test__(opts)

  test "no agent tool execs native code — base surface" do
    names = tool_names([])
    refute "run" in names, "the native `run` escape hatch must not be in the base tool surface"
    assert "shell" in names, "the in-WASM shell stays"
  end

  test "no agent tool execs native code — exec (trusted) surface" do
    names = tool_names(exec: true)
    refute "run" in names, "the native `run` escape hatch must not return even with exec: true"
    # The exec surface gains only HOST-BROKERED capabilities, never native exec.
    assert "git" in names and "publish" in names, "exec agents get host-brokered git/publish"
    assert "shell" in names
  end

  # ── (b) Workbooks.Sandbox is gone ───────────────────────────────────────────
  test "Workbooks.Sandbox (the native exec wrapper) no longer exists" do
    refute File.exists?(Path.expand("../host/sandbox.ex", __DIR__)),
           "sandbox.ex (the bwrap/seatbelt native isolator) must be deleted"

    refute Code.ensure_loaded?(Workbooks.Sandbox),
           "Workbooks.Sandbox must not be a loadable module"
  end

  test "no live code calls Sandbox.run / Sandbox.run_net" do
    host = Path.expand("../host", __DIR__)

    offenders =
      Path.wildcard(Path.join(host, "**/*.ex"))
      |> Enum.filter(fn f ->
        src = File.read!(f)
        # match a real call, not a comment/docstring mention (line must not be a comment)
        src
        |> String.split("\n")
        |> Enum.any?(fn line ->
          trimmed = String.trim_leading(line)
          not String.starts_with?(trimmed, "#") and
            Regex.match?(~r/Workbooks\.Sandbox\.(run|run_net)\b/, line)
        end)
      end)

    assert offenders == [], "these files still call the deleted native Sandbox: #{inspect(offenders)}"
  end

  # ── (c) compile entry points return lane-unavailable, never a native call ────
  # These previously shelled to native cargo/go/zig. With the native path removed
  # they must error honestly (and must not crash trying to find a native binary).
  test "native compiler fallbacks return lane-unavailable, not a native call" do
    alias Workbooks.CommandRegistry, as: CR

    assert {:error, {:lane_unavailable, _}} = CR.build_and_register_crate("c1", "ripgrep")
    assert {:error, {:lane_unavailable, _}} = CR.build_and_register_go("g1", "rsc.io/quote")
    assert {:error, {:lane_unavailable, _}} = CR.build_and_register_zig("z1", "/tmp/whatever.zig")
  end

  test "Build.build_one routes JS framework projects to honest unbuilt, never bun/npm" do
    # A JS project dir (package.json with a build script) has no in-sandbox lane for
    # a full framework build; it must come back UNBUILT, never via native bun/npm.
    dir = Path.join(System.tmp_dir!(), "nne-js-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "proj"))
    File.write!(Path.join(dir, "proj/package.json"), ~s({"scripts":{"build":"vite build"}}))

    report = Workbooks.Build.build(dir)
    assert report.built == []
    assert [%{reason: reason}] = report.unbuilt
    assert reason =~ "lane_unavailable"
  after
    :ok
  end
end
