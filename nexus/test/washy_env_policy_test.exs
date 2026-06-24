defmodule Nexus.WashyEnvPolicyTest do
  @moduledoc """
  Runtime-core seams for CLI-backed connections: a run-scoped environment (`env`) injected into the
  sandbox, and an exec policy (`exec_policy`) that can refuse a command before it runs. Generic — the
  runtime knows nothing about connections; the app builds env from a connection's credential and the
  policy from its scope allow-list. Skips when the C wasm lane (coreutils) isn't built.
  """
  use ExUnit.Case, async: false

  setup_all do
    if Nexus.Shell.available?(), do: %{ok: true}, else: %{skip: true}
  end

  setup %{} = ctx do
    if ctx[:skip], do: :ok, else: (
      dir = Path.join(System.tmp_dir!(), "wb-envpol-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      {:ok, dir: dir}
    )
  end

  test "injected env reaches the sandboxed program (environ passthrough)", %{} = ctx do
    if ctx[:skip], do: IO.puts("\n[skip] C wasm lane not built"), else: (
      out = Nexus.Shell.run("printenv GOOGLE_WORKSPACE_CLI_TOKEN", ctx.dir,
              env: ["GOOGLE_WORKSPACE_CLI_TOKEN=ya29.injected"]) |> elem(0)
      assert String.contains?(out, "ya29.injected")
    )
  end

  test "no env by default — the sandbox sees an empty environment", %{} = ctx do
    if ctx[:skip], do: :ok, else: (
      out = Nexus.Shell.run("env", ctx.dir) |> elem(0) |> String.trim()
      refute String.contains?(out, "GOOGLE_WORKSPACE_CLI_TOKEN")
    )
  end

  test "exec policy denies a blocked command, fails closed before it runs", %{} = ctx do
    if ctx[:skip], do: :ok, else: (
      # deny anything whose first word is "gws" with command group "admin" (mimics a blocked scope)
      policy = fn argv ->
        case argv do
          ["gws", "admin" | _] -> {:deny, "blocked by connection policy"}
          _ -> :ok
        end
      end

      {out, _} = Nexus.Shell.run("gws admin users list", ctx.dir, exec_policy: policy)
      assert String.contains?(out, "blocked by connection policy")
    )
  end

  test "exec policy allows a permitted command through", %{} = ctx do
    if ctx[:skip], do: :ok, else: (
      policy = fn argv ->
        case argv do
          ["gws", "admin" | _] -> {:deny, "blocked"}
          _ -> :ok
        end
      end

      # `echo` is permitted by the policy and runs normally (coreutils echo).
      out = Nexus.Shell.run("echo ok", ctx.dir, exec_policy: policy) |> elem(0) |> String.trim()
      assert out == "ok"
    )
  end
end
