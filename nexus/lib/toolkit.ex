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
    with {:ok, wasm} <- compile(lang(node), body) do
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
      true -> "c"
    end
  end

  @doc "Compile a toolkit's source to a `wasm32-wasi` command module."
  def compile("c", body), do: c_command(body, ".c", [])

  def compile("cpp", body), do: c_command(body, ".cpp", [])

  # Rust is the SIMPLE case: the rust lane already links crt1-command.o, so a plain `fn main()`
  # program IS a command module — no exports / keep-alive needed (that machinery is for the
  # component model). Same compiler we already have, just its natural command output.
  def compile("rust", body) do
    src = write_tmp(body, ".rs")

    case Nexus.Compilers.Rust.rust_compile_to_wasm(src, []) do
      {:ok, wasm, _logs} -> {:ok, wasm}
      {:error, _} = err -> err
    end
  end

  # Zig is NOT just-the-command-output like C/rust. Our zig path (zig1 build-obj -ofmt=c, the
  # bootstrap C backend) is EXPORTS-shaped — it can't lower a full `pub fn main()` std-I/O program
  # to a command module (which is why the zig unit lane only does `export fn`). A zig CLI toolkit
  # needs a C-main shim calling a zig export, or zig's self-hosted exe backend — a real follow-up.
  # Use `rust` or `c` for command-line toolkits today.
  def compile("zig", _body),
    do: {:error, {:zig_command_toolkits_unsupported, "our zig path is exports-only; author CLI toolkits in rust or c"}}

  def compile(lang, _body), do: {:error, {:unsupported_toolkit_lang, lang}}

  defp c_command(body, ext, opts) do
    Nexus.Compilers.C.compile_to_wasm(write_tmp(body, ext), [shape: :command] ++ opts)
  end

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
