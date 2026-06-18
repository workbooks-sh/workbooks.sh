defmodule Workbooks.Instance.ImportsCharacterizationTest do
  use ExUnit.Case, async: true
  alias Workbooks.Instance.Imports

  @moduledoc false

  # CHARACTERIZATION snapshot of the canonical WIT-typed Dock seam (§3, step 0): which
  # import names each capability projects TODAY. This locks current behavior so that
  # when the seam is reprojected over the single `Workbooks.Dock` registry (one
  # registry, many transports), the new map can be asserted byte-identical. Pure /
  # read-only — changes nothing about the live seam.
  @snapshot %{
    [] => ~w(session-info),
    ~w(vfs) => ~w(session-info vfs-query),
    ~w(commands) => ~w(session-info run-command),
    ~w(llm) => ~w(session-info llm-complete),
    ~w(browse) => ~w(session-info browse-fetch),
    ~w(parallel) => ~w(session-info run-command-many),
    ~w(vfs commands llm browse parallel) =>
      ~w(browse-fetch llm-complete run-command run-command-many session-info vfs-query),
    ~w(unknown-cap) => ~w(session-info)
  }

  test "for_caps projects exactly these import names per capability set (locked)" do
    for {caps, expected} <- @snapshot do
      keys = Imports.for_caps(caps, nil, %{}, []) |> Map.keys() |> Enum.sort()

      assert keys == Enum.sort(expected),
             "caps #{inspect(caps)} → #{inspect(keys)}, expected #{inspect(Enum.sort(expected))}"
    end
  end

  test "gating is by presence: an ungranted capability yields no import" do
    granted = Imports.for_caps(~w(llm), nil, %{}, []) |> Map.keys()
    assert "llm-complete" in granted

    ungranted = Imports.for_caps([], nil, %{}, []) |> Map.keys()
    refute "llm-complete" in ungranted
  end
end
