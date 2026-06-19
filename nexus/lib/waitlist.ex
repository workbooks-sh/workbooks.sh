defmodule Nexus.Waitlist do
  @moduledoc """
  The desktop-app interest list — a tiny durable store behind the lander's "get
  notified" modal. A DETS table on the persistent volume (`data_dir/waitlist.dets`),
  keyed by email so a re-submit updates rather than duplicates. Rows survive
  restarts/redeploys (it's on the /data volume).

  Public write path: `POST /api/waitlist {email, interest}` (see `Nexus.Server`,
  allow-listed in `Nexus.Auth`). Read path: `list/0` (used by an auth-gated route /
  a maintainer). No new DB dependency — same DETS approach as the control plane.
  """
  use GenServer

  @table :nexus_waitlist

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    File.mkdir_p!(Nexus.Config.data_dir())
    path = Nexus.Config.data_dir() |> Path.join("waitlist.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table, file: path, type: :set, auto_save: 5_000)
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.sync(@table)
    :dets.close(@table)
  end

  @doc """
  Record interest. Validates the email shape, normalizes, stores `{email,
  interest, at}`. Returns `:ok` | `{:error, reason}`. Idempotent per email.
  """
  def add(email, interest) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()
    interest = interest |> to_string() |> String.slice(0, 80)

    cond do
      not valid_email?(email) -> {:error, :invalid_email}
      true ->
        :dets.insert(@table, {email, %{email: email, interest: interest, at: System.system_time(:second)}})
        :ok
    end
  end

  def add(_, _), do: {:error, :invalid_email}

  @doc "All recorded entries (maintainer read)."
  def list do
    :dets.foldl(fn {_email, row}, acc -> [row | acc] end, [], @table)
    |> Enum.sort_by(& &1.at, :desc)
  end

  def count, do: :dets.info(@table, :size) || 0

  @doc "Remove an entry (maintainer / test cleanup)."
  def delete(email) when is_binary(email) do
    :dets.delete(@table, email |> String.trim() |> String.downcase())
    :ok
  end

  # A deliberately-loose RFC-ish check: one @, a dot in the domain, no spaces.
  defp valid_email?(e), do: Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, e)
end
