defmodule Nexus.Wit.TypesTest do
  use ExUnit.Case, async: true
  alias Nexus.{Literate, Wit}
  alias Nexus.Wit.Types

  test "wit/1 escapes reserved words and drops Elixir predicate/bang suffixes" do
    assert Types.wit(:from) == "%from"
    assert Types.wit(:static) == "%static"
    assert Types.wit(:interface) == "%interface"
    assert Types.wit(:valid?) == "valid"
    assert Types.wit(:save!) == "save"
    assert Types.wit(:risk_score) == "risk-score"
    assert Types.wit(:Lead) == "lead"
  end

  test "scalar/1 infers WIT scalars from default values" do
    assert Types.scalar("") == "string"
    assert Types.scalar(0) == "s32"
    assert Types.scalar(0.0) == "f64"
    assert Types.scalar(true) == "bool"
    assert Types.scalar(:new) == "string"
    assert Types.scalar([]) == "list<string>"
    assert Types.scalar(nil) == "string"
  end

  test "record/2 renders a WIT record from fields + defaults, kebab-casing names" do
    wit = Types.record(:Lead, name: "", revenue: 0, in_pipeline: false)
    assert wit =~ "record lead {"
    assert wit =~ "name: string,"
    assert wit =~ "revenue: s32,"
    assert wit =~ "in-pipeline: bool,"
  end

  test "enum/2 renders a WIT enum from atom cases" do
    wit = Types.enum(:statuses, [:new, :enriched, :scored])
    assert wit =~ "enum statuses {"
    assert wit =~ "  new,"
    assert wit =~ "  scored,"
  end

  test "Wit.world emits an atom-set module attribute as a WIT enum" do
    src = """
    server :lead do
      @statuses [:new, :enriched, :scored, :contacted]
      def of(l), do: l
    end
    """

    world = Literate.parse(src) |> Enum.find(&(&1.type == :code)) |> Wit.world()
    assert world =~ "enum statuses {"
    assert world =~ "contacted,"
  end

  test "variant/2 renders a WIT variant from tags" do
    wit = Types.variant(:result, [:ok, :err])
    assert wit =~ "variant %result {"
    assert wit =~ "ok(string),"
    assert wit =~ "err(string),"
  end

  test "Wit.world emits a result variant for a unit returning {:ok,_} | {:error,_}" do
    src = """
    server :enrich, grant: [net: "x"] do
      def enrich(lead) do
        case lookup(lead) do
          {:ok, r} -> {:ok, r}
          {:error, reason} -> {:error, reason}
        end
      end
    end
    """

    world = Literate.parse(src) |> Enum.find(&(&1.type == :code)) |> Wit.world()
    assert world =~ "variant %result {"
  end

  test "a unit that returns a plain value gets no spurious variant" do
    world = Literate.parse("server :score do\n  def score(_l), do: 1\nend\n") |> Enum.find(&(&1.type == :code)) |> Wit.world()
    refute world =~ "variant"
  end

  test "file_interface gathers file-level shared types (struct module + atom-set) into one interface" do
    src = """
    # Types

    defmodule Lead do
      defstruct name: "", revenue: 0, status: :new
    end

    @statuses [:new, :enriched, :scored, :contacted]
    """

    iface = Literate.parse(src) |> Wit.file_interface()
    assert iface =~ "interface types {"
    assert iface =~ "record lead {"
    assert iface =~ "enum statuses {"
    assert iface =~ "contacted,"
    # the status field's default :new is a member of the statuses enum → typed as it
    assert iface =~ "status: statuses,"
    assert iface =~ "name: string,"
  end

  test "record/3 types a field by its enum when the default atom is a member" do
    wit = Types.record(:lead, [status: :new, name: ""], [{:statuses, [:new, :scored]}])
    assert wit =~ "status: statuses,"
    assert wit =~ "name: string,"
  end

  test "file_interface is nil when a file declares no shared types" do
    src = "# Compute\n\nserver :score do\n  def score(_l), do: 1\nend\n"
    assert Wit.file_interface(Literate.parse(src)) == nil
  end

  test "Wit.world emits a unit's declared struct as a WIT record, named after the module" do
    src = """
    server :lead do
      defmodule Lead do
        defstruct name: "", revenue: 0, score: 0, status: :new
      end

      def of(l), do: l
    end
    """

    world = Literate.parse(src) |> Enum.find(&(&1.type == :code)) |> Wit.world()

    assert world =~ "record lead {"
    assert world =~ "name: string,"
    assert world =~ "revenue: s32,"
    assert world =~ "export of: func(a0: string) -> string;"
  end
end
