defmodule Workbooks.Config do
  @moduledoc """
  The **one** config surface for a runtime/nexus deployment — read deploy config here, not
  via scattered `System.get_env` calls (see `docs/RUNTIME-SIMPLICITY-CAMPAIGN.md`). Env vars
  are how a deployment *supplies* config; the rest of the code asks `Workbooks.Config`, so
  defaults and names live in exactly one place. Role *flags* (WB_WEB/WB_CLOUD/…) don't belong
  here — they're being replaced by structure (separate apps, loaded toolkits).
  """

  @doc "The runtime data directory (sessions, transcripts, caches). `WB_DATA`, default tmp."
  def data_dir, do: System.get_env("WB_DATA") || System.tmp_dir!()

  @doc "A path under the data dir."
  def data_path(sub), do: Path.join(data_dir(), sub)

  @doc "The provisioned profile dir (sandbox profiles). `WB_PROFILE_DIR`, default /opt/profile."
  def profile_dir, do: System.get_env("WB_PROFILE_DIR") || "/opt/profile"
end
