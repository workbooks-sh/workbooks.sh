defmodule Workbooks.Desktop do
  @moduledoc """
  Desktop daemon mode (`WB_DESKTOP=1`). The runtime runs as the ONE OCI image
  inside a local Linux container (krunvm/libkrun on mac), managed by the Tauri
  shell — decoupled from the app's lifetime (survives app quit). Inside the guest
  it binds a FIXED port on all interfaces (so the container's host→guest forward
  reaches it), mints a per-boot token, and writes a DISCOVERY FILE to a
  bind-mounted dir the host shell reads:

      <WB_DESKTOP_DIR>/runtime.json   (host: ~/Library/Application Support/sh.workbooks)
      { "port": 4000, "token": "…", "pid": 12345, "scheme": "http" }

  `port` is the GUEST port; the host maps it to a host port it chose and connects
  to `http://127.0.0.1:<hostport>` using `token` as `Authorization: Bearer …`.
  `Workbooks.Auth` accepts that token (only in this mode) and scopes to the local
  tenant. Token is memoized in :persistent_term so every caller agrees.
  """
  @pt_token {__MODULE__, :token}
  @tenant "local"

  @doc "Is the runtime running as the desktop daemon?"
  def enabled?, do: System.get_env("WB_DESKTOP") == "1"

  @doc "The local tenant id requests authenticate as in desktop mode."
  def tenant, do: @tenant

  @doc "The control-plane port the runtime binds inside the container (fixed; host forwards to it)."
  def port, do: String.to_integer(System.get_env("PORT", "4000"))

  @doc "The interface to bind on. In-container we must accept the host→guest forward → all interfaces."
  def bind_ip, do: {0, 0, 0, 0}

  @doc "The per-boot bearer token shared with the shell via the discovery file."
  def token do
    case :persistent_term.get(@pt_token, nil) do
      nil ->
        t = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        :persistent_term.put(@pt_token, t)
        t

      t -> t
    end
  end

  @doc "Write the discovery file so the Tauri shell can find + authenticate to us."
  def write_discovery! do
    path = discovery_path()
    File.mkdir_p!(Path.dirname(path))

    payload =
      Jason.encode!(%{
        port: port(),
        token: token(),
        pid: System.pid() |> to_string() |> String.to_integer(),
        scheme: "http"
      })

    # 0600 — the token is a local credential; keep it user-only.
    File.write!(path, payload)
    _ = File.chmod(path, 0o600)
    path
  end

  @doc "Best-effort removal of the discovery file (graceful shutdown)."
  def clear_discovery do
    _ = File.rm(discovery_path())
    :ok
  end

  @doc """
  The discovery-file path. `WB_DESKTOP_DIR` overrides; otherwise the per-OS app
  data dir (macOS Application Support, else XDG-ish ~/.local/share).
  """
  def discovery_path do
    dir =
      System.get_env("WB_DESKTOP_DIR") ||
        case :os.type() do
          {:unix, :darwin} -> Path.join([System.user_home!(), "Library", "Application Support", "sh.workbooks"])
          _ -> Path.join([System.user_home!(), ".local", "share", "sh.workbooks"])
        end

    Path.join(dir, "runtime.json")
  end
end
