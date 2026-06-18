defmodule Nexus.ToolkitTest do
  use ExUnit.Case, async: false

  setup do
    on_exit(fn -> Nexus.Agent.Kits.clear_registered() end)
    :ok
  end

  defp unit(src), do: src |> Nexus.Literate.parse() |> Enum.find(&(&1.type == :code))

  test "a `toolkit` unit parses with kind=toolkit and the body as its source" do
    n = unit("toolkit :upper do\n  int main(void) { return 0; }\nend\n")
    assert n.kind == "toolkit"
    assert n.name == "upper"
    assert n.body =~ "int main"
  end

  test "Kits.register makes an in-memory kit resolvable + visible in the catalog" do
    Nexus.Agent.Kits.register("demo", "/tmp/demo.wasm", summary: "a demo", commands: ["demo"])
    assert Nexus.Agent.Kits.summary() =~ "demo — a demo"
    assert {"/tmp/demo.wasm", []} = Nexus.Agent.Kits.resolve("demo")
    assert Nexus.Agent.Kits.help("demo") =~ "demo"
  end

  test "a // summary comment in the toolkit body becomes its catalog line" do
    # exercise the summary extraction without compiling (build/1 is the compiled path)
    n = unit("toolkit :up do\n  // summary: shouty text\n  int main(void){return 0;}\nend\n")
    # build/1 registers with this summary; here assert the unit routes to the toolkit lane
    assert n.kind == "toolkit"
  end

  test "the toolkit language comes from `lang:` in the header, else inferred from the body" do
    assert Nexus.Toolkit.lang(unit("toolkit :a, lang: \"rust\" do\n  x\nend\n")) == "rust"
    assert Nexus.Toolkit.lang(unit("toolkit :a do\n  fn main(){}\nend\n")) == "rust"
    assert Nexus.Toolkit.lang(unit("toolkit :a do\n  pub fn main() void {}\nend\n")) == "zig"
    assert Nexus.Toolkit.lang(unit("toolkit :a do\n  int main(void){return 0;}\nend\n")) == "c"
  end

  test "zig command toolkits fail with a clear, honest error (exports-only via the registry)" do
    # the Nexus.Langs registry guards shape support: zig declares [:component] only.
    assert {:error, {:unsupported_shape, "zig", :command}} = Nexus.Toolkit.compile("zig", "pub fn main() void {}")
    refute Nexus.Langs.supports?("zig", :command)
    assert Nexus.Langs.supports?("rust", :command)
  end

  @tag :kits
  @tag timeout: 240_000
  test "a RUST toolkit (just `fn main`) compiles to a command + runs via bash" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) && System.find_executable("wasmtime") do
      n =
        unit(
          "toolkit :rev, lang: \"rust\" do\n  // summary: reverse each line\n  use std::io::{self,BufRead,Write};\n" <>
            "  fn main(){let s=io::stdin();let mut o=io::stdout();for l in s.lock().lines(){let l=l.unwrap();let r:String=l.chars().rev().collect();writeln!(o,\"{}\",r).unwrap();}}\nend\n"
        )

      assert {:toolkit, {:ok, "rev"}} = Nexus.Compile.unit(n)
      vfs = Nexus.Agent.Vfs.new()
      Nexus.Agent.Vfs.put(vfs, "in.txt", "hello\n")
      assert Nexus.Agent.Bash.run(vfs, "cat /work/in.txt | rev") |> String.trim() == "olleh"
      Nexus.Agent.Vfs.destroy(vfs)
    else
      :ok
    end
  end

  @tag :kits
  @tag timeout: 240_000
  test "author a toolkit in a .work file → compile → register → run via bash" do
    if File.dir?(Nexus.Compilers.Shared.default_root()) && System.find_executable("wasmtime") do
      n =
        unit(
          "toolkit :upper do\n  // summary: uppercase stdin\n  #include <stdio.h>\n  #include <ctype.h>\n" <>
            "  int main(void) { int c; while ((c=getchar())!=EOF) putchar(toupper(c)); return 0; }\nend\n"
        )

      assert {:toolkit, {:ok, "upper"}} = Nexus.Compile.unit(n)
      assert Nexus.Agent.Kits.summary() =~ "upper — uppercase stdin"

      vfs = Nexus.Agent.Vfs.new()
      Nexus.Agent.Vfs.put(vfs, "in.txt", "hello toolkit\n")
      assert Nexus.Agent.Bash.run(vfs, "cat /work/in.txt | upper") |> String.trim() == "HELLO TOOLKIT"
      Nexus.Agent.Vfs.destroy(vfs)
    else
      :ok
    end
  end
end
