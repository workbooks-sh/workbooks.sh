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
  def build(%{kind: "toolkit", name: name, body: body} = node) do
    lang = Map.get(node, :lang) || "c"

    with {:ok, wasm} <- compile(lang, body) do
      Nexus.Agent.Kits.register(name, wasm, summary: summary(body, name), commands: [name])
      {:ok, name}
    end
  end

  @doc "Compile a toolkit's source to a `wasm32-wasi` command module."
  def compile("c", body) do
    src = Path.join(System.tmp_dir!(), "nxtk_#{System.unique_integer([:positive])}.c")
    File.write!(src, body)
    Nexus.Compilers.C.compile_to_wasm(src, shape: :command)
  end

  def compile(lang, _body), do: {:error, {:unsupported_toolkit_lang, lang}}

  # A toolkit's one-line summary: a leading `// summary: …` (or `# summary: …`) comment, else a default.
  defp summary(body, name) do
    case Regex.run(~r/^\s*(?:\/\/|#)\s*summary:\s*(.+)$/m, body) do
      [_, s] -> String.trim(s)
      _ -> "the #{name} toolkit (a wasm CLI)"
    end
  end
end
