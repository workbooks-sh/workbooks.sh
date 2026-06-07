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

  # Two kinds of built-in: {:src, lang, code} compiled on first use, and
  # {:wasm, path} a prebuilt artifact (e.g. jq — a real CLI compiled to wasm).
  @builtins %{
    # A proof command: uppercases stdin. Source-built (Javy) on first use.
    "upper" =>
      {:src, "js",
       ~S|const b=new Uint8Array(8192);let n,t=0;while((n=Javy.IO.readSync(0,b.subarray(t)))>0)t+=n;const s=new TextDecoder().decode(b.subarray(0,t)).trim();Javy.IO.writeSync(1,new TextEncoder().encode(s.toUpperCase()));|},
    # Real jq: a wasi-clean jaq-interpret wrapper compiled to wasm (commands/jq/).
    # Stdin protocol: first line = filter, rest = JSON.
    "jq" => {:wasm, "build/commands/jq.wasm"},
    # Real grep: a regex-crate wrapper (commands/grep/). Stdin protocol: first
    # line = pattern, rest = text; matching lines printed. (ripgrep's recursive
    # file walk doesn't fit a stdin command; line-grep is the command form.)
    "grep" => {:wasm, "build/commands/grep.wasm"}
  }

  @doc "Registered command names."
  def list, do: Map.keys(@builtins)

  @doc "Run a registered command by name with input → {:ok, output} | {:error, reason}."
  def run(name, input) do
    case @builtins[name] do
      nil -> {:error, {:unknown_command, name}}
      spec -> run_builtin(spec, input)
    end
  end

  defp run_builtin({:wasm, path}, input),
    do: {:ok, Workbooks.PackageManager.run(path, input) |> String.trim()}

  defp run_builtin({:src, lang, src}, input) do
    case Workbooks.PackageManager.build(%{"name" => "cmd", "lang" => lang, "src" => src}) do
      {_, _, {:ok, wasm, _}} -> {:ok, Workbooks.PackageManager.run(wasm, input) |> String.trim()}
      {_, _, err} -> {:error, err}
    end
  end
end
