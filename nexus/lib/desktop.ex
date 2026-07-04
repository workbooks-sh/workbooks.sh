defmodule Nexus.Desktop do
  @moduledoc """
  The desktop ↔ nexus boot handshake. When the desktop app boots a local nexus (in a krunvm/container
  with `WB_DESKTOP_DIR` bind-mounted), the runtime must publish where it's listening + a per-boot
  token so the host daemon can reach it. We write a small discovery file the daemon polls:

      $WB_DESKTOP_DIR/runtime.json  →  {port, token, scheme, host, pid, mode}

  This JSON is a **generated machine artifact at the desktop↔runtime tool boundary** (the Rust daemon
  the desktop RCP client reads exactly this shape) — the legitimate kind of JSON, not
  authored config. The token is `Nexus.Desktop.token/0`; the Bearer auth adapter can enforce it.
  """
  @key {__MODULE__, :token}

  @doc "The per-boot bearer token (generated once, stable for the life of the node)."
  def token do
    case :persistent_term.get(@key, nil) do
      nil ->
        t = Nexus.Secrets.get("NEXUS_DATA_TOKEN") || Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
        :persistent_term.put(@key, t)
        t

      t ->
        t
    end
  end

  @doc """
  Write the discovery file the desktop daemon reads, if `WB_DESKTOP_DIR` is set (i.e. we were booted
  by the desktop). No-op otherwise. Returns `{:ok, path} | :skip`.
  """
  def write_discovery(port) do
    case System.get_env("WB_DESKTOP_DIR") do
      dir when is_binary(dir) and dir != "" ->
        File.mkdir_p!(dir)
        path = Path.join(dir, "runtime.json")

        payload = %{
          port: port,
          token: token(),
          scheme: "http",
          host: "127.0.0.1",
          pid: System.pid(),
          mode: System.get_env("WB_EMBED") || "container"
        }

        # atomic publish: write a temp then rename, so the daemon never reads a half-written file.
        tmp = path <> ".tmp"
        File.write!(tmp, Jason.encode!(payload))
        File.rename!(tmp, path)
        {:ok, path}

      _ ->
        :skip
    end
  end
end
