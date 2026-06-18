defmodule Workbooks.WitWriteTest do
  use ExUnit.Case, async: true
  alias Workbooks.Wit

  setup do
    src = Path.join(System.tmp_dir!(), "wbwrite_src_#{System.unique_integer([:positive])}")
    out = Path.join(System.tmp_dir!(), "wbwrite_out_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(src, "lib"))

    File.write!(Path.join(src, "types.work"), """
    # Types

    defmodule Lead do
      defstruct name: "", revenue: 0
    end
    """)

    File.write!(Path.join([src, "lib", "enrich.work"]), """
    # Enrich

    server :enrich, grant: [net: "x"] do
      def enrich(%Lead{} = lead), do: Dock.fetch("u")
    end
    """)

    on_exit(fn ->
      File.rm_rf!(src)
      File.rm_rf!(out)
    end)

    {:ok, src: src, out: out}
  end

  test "write_packages writes one .wit per file, each valid and cross-file resolved", %{src: src, out: out} do
    {:ok, written} = Wit.write_packages(src, out)

    assert length(written) == 2
    assert Enum.all?(written, &File.regular?/1)

    enrich_wit = Path.join(out, "enrich.wit")
    assert File.read!(enrich_wit) =~ "world enrich {"
    # cross-file: %Lead{} param types as lead (Lead defined in types.work)
    assert File.read!(enrich_wit) =~ "export enrich: func(a0: lead)"

    # each written file is valid WIT
    for path <- written do
      case Wit.validate(File.read!(path)) do
        :ok -> :ok
        {:error, "wasm-tools unavailable" <> _} -> :ok
        {:error, msg} -> flunk("#{Path.basename(path)} invalid:\n#{msg}")
      end
    end
  end
end
