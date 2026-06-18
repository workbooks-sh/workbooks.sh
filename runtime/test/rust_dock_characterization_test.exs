defmodule Workbooks.RustDockCharacterizationTest do
  use ExUnit.Case, async: true
  alias Workbooks.RustDock

  @moduledoc false

  # CHARACTERIZATION snapshot of the RustDock core-module ABI seam (§3, step 0 for this
  # seam): which `env.host_*` import names each profile projects TODAY. Locks the surface
  # so a future reprojection over `Workbooks.Dock` (the core ptr/len transport) can be
  # asserted byte-identical. Pure / read-only — changes nothing about the live seam.
  @snapshot %{
    minimal:
      ~w(host_exec host_ffmpeg_encode host_kv_get host_kv_put host_log host_now
         host_parallel_map host_poll host_publish host_sign host_tcp host_tls host_udp),
    network:
      ~w(host_exec host_ffmpeg_encode host_http_get host_http_get_many host_kv_get
         host_kv_put host_log host_now host_parallel_map host_poll host_publish host_sign
         host_tcp host_tls host_udp)
  }

  test "RustDock env.* import surface per profile is locked" do
    for {profile, expected} <- @snapshot do
      keys =
        RustDock.imports(profile: profile)
        |> Map.fetch!("env")
        |> Map.keys()
        |> Enum.sort()

      assert keys == Enum.sort(expected),
             "profile #{profile} → #{inspect(keys)}, expected #{inspect(Enum.sort(expected))}"
    end
  end

  test "ambient host_now/host_log are always present; http egress only with the network profile" do
    minimal = RustDock.imports(profile: :minimal) |> Map.fetch!("env") |> Map.keys()
    network = RustDock.imports(profile: :network) |> Map.fetch!("env") |> Map.keys()

    assert "host_now" in minimal and "host_log" in minimal
    refute "host_http_get" in minimal
    assert "host_http_get" in network
  end
end
