defmodule Nexus.AuditTest do
  use ExUnit.Case, async: true

  defp code(src), do: src |> Nexus.Literate.parse() |> Enum.find(&(&1.type == :code))

  test "a unit using a host cap it did not grant is flagged" do
    u = code("c :a do\n  extern void emit(const char* p, int n);\n  void g(void){ emit(\"x\", 1); }\nend\n")
    assert Nexus.Audit.unit(u) == ["emit"]
  end

  test "granting the cap clears the violation" do
    u = code("c :a, grant: [emit] do\n  extern void emit(const char* p, int n);\n  void g(void){ emit(\"x\", 1); }\nend\n")
    assert Nexus.Audit.unit(u) == []
  end

  test "a unit using no host caps is clean regardless of grants" do
    u = code("c :a do\n  int dbl(int x){ return x*2; }\nend\n")
    assert Nexus.Audit.unit(u) == []
  end

  test "workbook/1 maps only the violating units" do
    dir = Path.join(System.tmp_dir!(), "au_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "bad.work"), "c :bad do\n  extern void emit(const char* p, int n);\n  void g(void){ emit(\"x\", 1); }\nend\n")
    File.write!(Path.join(dir, "ok.work"), "c :ok, grant: [emit] do\n  extern void emit(const char* p, int n);\n  void g(void){ emit(\"x\", 1); }\nend\n")

    assert %{"bad" => ["emit"]} = Nexus.Audit.workbook(dir)
    File.rm_rf!(dir)
  end
end
