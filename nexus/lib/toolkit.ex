defmodule Nexus.Toolkit do
  @moduledoc """
  Author a **toolkit** in a `.work` file. A toolkit is a wrapped CLI — a `wasm32-wasi` command
  (`main()` reading argv/stdin, writing stdout) — the unit of capability an agent uses through
  `bash`. This is the dogfooding completion: the same compiler that builds resource/render units
  builds the kits agents run.

      toolkit :upper do
        // summary: uppercase stdin
        #include <stdio.h>
        #include <ctype.h>
        int main(void) { int c; while ((c=getchar())!=EOF) putchar(toupper(c)); return 0; }
      end

  `Nexus.Toolkit.build/1` compiles the body to a command module (C lane, `:command` shape) and
  registers it in `Nexus.Agent.Kits` — instantly callable as `upper` in any agent's `bash`, with the
  summary surfaced in the kit catalog (progressive disclosure). `Compile.unit` routes `toolkit` here.

  Default language is C (the natural CLI language, and our command lane). `lang:` can select another
  when those command lanes land.
  """

  @doc "Compile + register a `toolkit` unit. Returns `{:ok, name} | {:error, reason}`."
  def build(%{kind: "toolkit"} = node) do
    case lang(node) do
      "elixir" -> Nexus.Toolkit.Js.build(node)
      lang -> build_cli(lang, node)
    end
  end

  defp build_cli(lang, %{name: name, body: body}) do
    with {:ok, wasm} <- compile(lang, body) do
      Nexus.Agent.Kits.register(name, wasm, summary: summary(body, name), commands: [name])
      {:ok, name}
    end
  end

  @doc """
  The toolkit's language: `lang: <x>` in the header, else inferred from the body (`fn main` → rust,
  `pub fn main` → zig, else C). Default C — the natural CLI language and our command lane.
  """
  def lang(%{header: header} = node) when is_binary(header) do
    case Regex.run(~r/lang:\s*"?([a-z+]+)"?/, header) do
      [_, l] -> l
      _ -> infer(Map.get(node, :body, ""))
    end
  end

  def lang(node), do: infer(Map.get(node, :body, ""))

  defp infer(body) do
    cond do
      body =~ ~r/\bpub\s+fn\s+main\b/ -> "zig"
      body =~ ~r/\bfn\s+main\b/ -> "rust"
      # Elixir-authored toolkit: `def …` (C/Rust/Zig use `fn`, not `def`). Transpiled → JS, run in the
      # StarlingMonkey eval-host (Nexus.Toolkit.Js) rather than compiled to a wasm CLI.
      body =~ ~r/\bdef\s+\w/ -> "elixir"
      true -> "c"
    end
  end

  @doc """
  Compile a toolkit's source to a `wasm32-wasi` command module, via the `Nexus.Langs` registry —
  the explicit set of WebAssembly compiler languages. A new language (implement `Nexus.Lang` +
  `Nexus.Langs.register/1`) becomes available here automatically. C/Rust support `:command`; Zig is
  exports-only (a clear error).
  """
  def compile(lang, body) do
    # C/C++ toolkits compile to Wasmer-runnable wasm via the WASIX/EH lane (Phase 3) when its toolchain
    # is present — so the toolkit runs in the agent's wasmer bash (a real pipe). Otherwise fall back to
    # the registry lane (the old wasm32-wasi command format).
    if lang in ["c", "cpp"] and Nexus.Wasmer.Cc.available?() do
      Nexus.Wasmer.Cc.compile(body)
    else
      src = write_tmp(body, ext_for(lang))
      Nexus.Langs.compile(lang, src, :command)
    end
  end

  defp ext_for("rust"), do: ".rs"
  defp ext_for("zig"), do: ".zig"
  defp ext_for("cpp"), do: ".cpp"
  defp ext_for(_), do: ".c"

  defp write_tmp(body, ext) do
    src = Path.join(System.tmp_dir!(), "nxtk_#{System.unique_integer([:positive])}#{ext}")
    File.write!(src, body)
    src
  end

  # A toolkit's one-line summary: a leading `// summary: …` (or `# summary: …`) comment, else a default.
  defp summary(body, name) do
    case Regex.run(~r/^\s*(?:\/\/|#)\s*summary:\s*(.+)$/m, body) do
      [_, s] -> String.trim(s)
      _ -> "the #{name} toolkit (a wasm CLI)"
    end
  end
end
