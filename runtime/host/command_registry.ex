defmodule Workbooks.CommandRegistry do
  @moduledoc """
  The in-WASM command registry (wb-11ck.21). A *command* is a CLI *converted to a
  runnable WASM module* — stdin in, stdout out — that a Workbook/agent invokes by
  name through the `run-command` Dock import (and, once it lands, the bash-type
  in-WASM shell, wb-11ck.20). The in-WASM equivalent of a CLI on $PATH, except
  the CLI is itself sandboxed WASM. Think jq, ripgrep, grep.

  Relationship to toolkits (L4, ARCHITECTURE.org): a *toolkit* is our version of
  Claude Code skills — a progressive-disclosure skill doc bundled with the whole
  CLI it documents. That CLI is converted to commands (here); the skill tells the
  agent which commands exist and how to call them. So a command is the runnable
  form of a toolkit's CLI; the skill/discovery surface is the separate L4 piece.
  A command may also need a capability (network → `net-fetch` + the secret model);
  that's a property of the command, not a different layer.

  Built-ins are either source compiled on first use (`upper`, Javy) or prebuilt
  wasm artifacts: `jq` (a jaq-interpret wrapper) and `grep` (a regex wrapper),
  both real CLIs compiled to wasm. `oql` is the kernel (a Component), reachable
  directly, not as a stdio command.
  """

  # Built-in shapes (each carries an ARG MODE — the last element):
  #   {:src, lang, code, mode}  compiled on first use
  #   {:wasm, path, mode}       a prebuilt artifact (a real CLI compiled to wasm)
  # Arg mode reconciles two conventions:
  #   :argv   — args passed as real wasmtime argv (the universal CLI ABI). The
  #             default for auto-wrapped upstream CLIs (e.g. sd, ripgrep).
  #   :stdin1 — args become the FIRST stdin line (our legacy jq/grep protocol,
  #             where the binary reads its filter/pattern from line 1 of stdin).
  @builtins %{
    # A proof command: uppercases stdin. Source-built (Javy) on first use.
    "upper" =>
      {:src, "js",
       ~S|const b=new Uint8Array(8192);let n,t=0;while((n=Javy.IO.readSync(0,b.subarray(t)))>0)t+=n;const s=new TextDecoder().decode(b.subarray(0,t)).trim();Javy.IO.writeSync(1,new TextEncoder().encode(s.toUpperCase()));|,
       :argv},
    # Real jq: a wasi-clean jaq-interpret wrapper compiled to wasm (commands/jq/).
    # Stdin protocol: first line = filter, rest = JSON.
    "jq" => {:wasm, "build/commands/jq.wasm", :stdin1},
    # Real grep: a regex-crate wrapper (commands/grep/). Stdin protocol: first
    # line = pattern, rest = text; matching lines printed. (ripgrep's recursive
    # file walk doesn't fit a stdin command; line-grep is the command form.)
    "grep" => {:wasm, "build/commands/grep.wasm", :stdin1}
  }

  @doc "Registered command names."
  def list, do: Map.keys(@builtins)

  @doc "Run a registered command with stdin `input` (no argv) → {:ok, out} | {:error, reason}."
  def run(name, input), do: run(name, input, [])

  @doc """
  Run a registered command with stdin `input` AND `argv` (a list) → {:ok, out} |
  {:error, reason}. `dirs` are host paths preopened into the guest (WASI --dir) for
  file-mode CLIs. How argv reaches the command is per its registered arg mode:
  :argv passes real wasmtime argv; :stdin1 folds argv into the first stdin line.
  """
  def run(name, input, argv, dirs \\ []) when is_list(argv) do
    case @builtins[name] do
      nil -> {:error, {:unknown_command, name}}
      spec -> run_builtin(spec, input, argv, dirs)
    end
  end

  defp run_builtin({:wasm, path, mode}, input, argv, dirs) do
    {stdin, args} = apply_argmode(mode, input, argv)
    {:ok, Workbooks.PackageManager.run(path, stdin, args, dirs) |> String.trim()}
  end

  defp run_builtin({:src, lang, src, mode}, input, argv, dirs) do
    case Workbooks.PackageManager.build(%{"name" => "cmd", "lang" => lang, "src" => src}) do
      {_, _, {:ok, wasm, _}} ->
        {stdin, args} = apply_argmode(mode, input, argv)
        {:ok, Workbooks.PackageManager.run(wasm, stdin, args, dirs) |> String.trim()}

      {_, _, err} ->
        {:error, err}
    end
  end

  # :argv → args go to wasmtime as argv. :stdin1 → args become the first stdin
  # line (legacy), so the wasm sees no argv. Empty argv is a no-op either way.
  defp apply_argmode(_mode, input, []), do: {input, []}
  defp apply_argmode(:argv, input, argv), do: {input, argv}
  defp apply_argmode(:stdin1, input, argv), do: {Enum.join(argv, " ") <> "\n" <> input, []}
end
