defmodule Nexus.GitPreReceiveHardeningTest do
  @moduledoc """
  Guardrail for the seam-0.1 eval-boundary hardening (red-team wb-10lz / wb-onui / wb-livx). Provisions
  a real bare repo and asserts the generated `pre-receive` hook has the security properties — so a
  refactor can't silently regress them.
  """
  use ExUnit.Case, async: true

  setup do
    base = Path.join(System.tmp_dir!(), "wb-prehook-#{System.unique_integer([:positive])}")
    bare = Path.join(base, "repo.git")
    work = Path.join(base, "work")
    File.mkdir_p!(bare)
    File.mkdir_p!(work)
    on_exit(fn -> File.rm_rf(base) end)
    Nexus.Git.provision_remote(bare, work)
    {:ok, hook: File.read!(Path.join(bare, "hooks/pre-receive"))}
  end

  test "authorship gate runs BEFORE the compile gate", %{hook: hook} do
    sig_at = :binary.match(hook, "sig_gate_env!") |> elem(0)
    compile_at = :binary.match(hook, "gate_from_env") |> elem(0)
    assert sig_at < compile_at, "sig_gate must precede the compile gate so unsigned pushes never compile"
  end

  test "compile gate runs with the high-value secrets scrubbed from its env", %{hook: hook} do
    # the compile-gate line must strip the KEK + Fly token before the gate BEAM boots
    assert hook =~ ~r/env .*-u WB_ENV_MASTER_KEY/
    assert hook =~ "-u FLY_API_TOKEN"
    assert hook =~ "-u OPENROUTER_API_KEY"
    assert hook =~ "WB_GATE_TREE="
  end

  test "push-controlled values are passed via env, never spliced into an eval source string", %{hook: hook} do
    # the eval bodies are fixed, data-free calls
    assert hook =~ ~s|eval "Nexus.Git.sig_gate_env!()"|
    assert hook =~ ~s|eval "Nexus.Compile.gate_from_env()"|
    # the old/new refs reach Elixir only as env vars, never interpolated into the eval string
    refute hook =~ ~r/Nexus\.Compile\.gate\(\\?"\$/
    refute hook =~ ~r/sig_gate!\(\\?"#\{/
  end

  test "refs/notes/* pushes are still rejected (meter-note integrity preserved)", %{hook: hook} do
    assert hook =~ "refs/notes/*"
    assert hook =~ "not allowed"
  end
end
