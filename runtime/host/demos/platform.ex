defmodule Workbooks.Demos.Platform do
  @moduledoc "Demos for the platform layer: auth, git/federation, BYOD storage, secrets, toolkits, bundles, durability."

  import Workbooks, only: [deploy: 3]

  @doc "Auth demo: mint a BetterAuth-shaped HS256 JWT locally, push it through the Auth plug, return the tenant."
  def demo_auth do
    Workbooks.Auth.Guardian.install_config()

    {:ok, token, _} =
      Workbooks.Auth.Guardian.encode_and_sign(
        %{user_id: "user-1"},
        %{"organizationId" => "org-42", "sessionId" => "sess-9"}
      )

    Plug.Test.conn(:get, "/")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Workbooks.Auth.call([])
    |> Map.get(:assigns)
    |> Map.get(:tenant)
  end

  @doc """
  Prod-auth demo: verify a real RS256 JWT against a JWKS — no live gateway.
  Generate an RSA keypair, seed its public half as the JWKS, mint a token with the
  private key, verify it through Guardian + SecretFetcher (key chosen by `kid`).
  """
  def demo_auth_jwks do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, pub} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    pub = Map.merge(pub, %{"kid" => "kid-1", "use" => "sig", "alg" => "RS256"})
    url = "https://gateway.example/api/auth/jwks"
    Workbooks.Auth.JWKS.seed(url, [pub])

    System.put_env("WB_JWKS_URL", url)
    Workbooks.Auth.Guardian.install_config()

    claims = %{
      "sub" => "user_42",
      "organizationId" => "org_acme",
      "sessionId" => "sess_1",
      "iss" => "betterauth",
      "exp" => System.system_time(:second) + 3600
    }

    {_, token} = JOSE.JWT.sign(jwk, %{"alg" => "RS256", "kid" => "kid-1"}, claims) |> JOSE.JWS.compact()
    result = Workbooks.Auth.Guardian.resource_from_token(token)

    System.delete_env("WB_JWKS_URL")
    Workbooks.Auth.Guardian.install_config()

    case result do
      {:ok, identity, _} -> %{alg: "RS256", verified: true, tenant: identity.tenant_id, user: identity.user_id}
      other -> %{alg: "RS256", verified: false, error: other}
    end
  end

  @doc "Git demo: deploy a Workbook twice into a throwaway tenant repo, return the commit log + latest diff."
  def demo_git do
    tenant = "demo-git"
    File.rm_rf!(Workbooks.Git.repo_path(tenant))
    deploy("report", "* Report\n  build it\n", tenant)
    deploy("report", "* Report\n  build it, now emails it\n", tenant)
    %{commits: Workbooks.Git.log(tenant), diff: Workbooks.Git.diff(tenant)}
  end

  @doc "Identity-bridge demo: save a Workbook as a specific identity, read back git attribution + the tenant DID."
  def demo_git_identity do
    tenant = "org-42"
    File.rm_rf!(Workbooks.Git.repo_path(tenant))
    id = Workbooks.Git.identity(tenant, "Alice")
    {:ok, sha} = Workbooks.Git.save(id, "report", "* Report\n  v1\n")
    %{sha: sha, author: Workbooks.Git.author(tenant), did: Workbooks.Git.did(tenant)}
  end

  @doc "Federation demo: deploy then publish a Workbook over Radicle — returns its RID + delegates (no network)."
  def demo_radicle do
    tenant = "demo-rad-#{System.unique_integer([:positive])}"
    deploy("report", "* Report\n  federate it\n", tenant)
    rid = Workbooks.Git.publish(tenant)
    %{tenant: tenant, rid: rid, delegates: Workbooks.Git.delegates(tenant), node_did: Workbooks.Git.ensure_rad_profile()}
  end

  @doc "BYOD demo (L2): the storage seam — write/read/query through the Backend behaviour (SQLite default)."
  def demo_backend do
    {:ok, b} = Workbooks.Backend.open(:default)
    {:ok, _} = Workbooks.Backend.write(b, "notes", %{"id" => "n1", "tag" => "x", "body" => "alpha"})
    {:ok, _} = Workbooks.Backend.write(b, "notes", %{"id" => "n2", "tag" => "y", "body" => "beta"})
    {:ok, x} = Workbooks.Backend.read(b, "notes", %{"tag" => "x"})
    {:ok, count} = Workbooks.Backend.query(b, "SELECT COUNT(*) FROM notes", [])
    Workbooks.Backend.close(b)
    %{engine: "sqlite", wrote: 2, read_tag_x: x, raw_count: count}
  end

  @doc """
  BYOD Postgres demo (wb-11ck.24): the same Backend behaviour against a LIVE PG.
  Connects to a local PG (WB_PG_* or localhost:5433); cleanly :unavailable if none.
  """
  def demo_backend_postgres do
    opts = [
      hostname: System.get_env("WB_PG_HOST", "localhost"),
      port: String.to_integer(System.get_env("WB_PG_PORT", "5433")),
      username: System.get_env("WB_PG_USER", "postgres"),
      password: System.get_env("WB_PG_PASS", ""),
      database: System.get_env("WB_PG_DB", "workbooks")
    ]

    case Workbooks.Backend.Postgres.init(opts) do
      {:ok, conn} ->
        b = {Workbooks.Backend.Postgres, conn}
        coll = "pgnotes_#{System.unique_integer([:positive])}"
        {:ok, _} = Workbooks.Backend.write(b, coll, %{"id" => "p1", "tag" => "x", "body" => "alpha"})
        {:ok, _} = Workbooks.Backend.write(b, coll, %{"id" => "p2", "tag" => "y", "body" => "beta"})
        {:ok, x} = Workbooks.Backend.read(b, coll, %{"tag" => "x"})
        {:ok, count} = Workbooks.Backend.query(b, ~s|SELECT count(*) FROM "#{coll}"|, [])
        Workbooks.Backend.close(b)
        %{engine: "postgres", read_tag_x: x, raw_count: count}

      {:error, _} ->
        %{engine: "postgres", status: :unavailable}
    end
  catch
    :exit, _ -> %{engine: "postgres", status: :unavailable}
  end

  @doc "Secrets-by-reference demo: a guest checks existence only; the host injects {{secret:NAME}} on egress."
  def demo_secrets do
    Application.put_env(:workbooks, :secrets, %{"STRIPE_KEY" => "sk_live_DEADBEEF"})
    template = "authorization: Bearer {{secret:STRIPE_KEY}} (missing: {{secret:NOPE}})"
    injected = Workbooks.Secret.inject(template)

    result = %{
      guest_existence_check: %{stripe: Workbooks.Secret.present?("STRIPE_KEY"), nope: Workbooks.Secret.present?("NOPE")},
      host_injected_request: injected,
      missing_stays_literal: String.contains?(injected, "{{secret:NOPE}}")
    }

    Application.delete_env(:workbooks, :secrets)
    result
  end

  # A small Context Tree: one agent + three toolkits (each :toolkit: names its CLI + a skill index).
  @context_tree """
  * Workhorse                                                  :agent:
    :PROPERTIES:
    :ID:        workhorse
    :TOOLKITS:  text jq git
    :END:
    The default agent. Its one tool is the Dock/shell; toolkits are the CLIs it drives.

  * text — string transforms                                  :toolkit:
    :PROPERTIES:
    :ID:        text
    :CLI_BIN:   upper
    :STATUS:    stable
    :SKILL_DIR: skills/
    :END:
    Normalize/transform text. Its CLI `upper` runs as a sandboxed WASM command.

  * jq — JSON wrangling                                        :toolkit:
    :PROPERTIES:
    :ID:        jq
    :CLI_BIN:   jq
    :STATUS:    stable
    :SKILL_DIR: skills/
    :END:
    Slice and filter JSON. Skills: overview, select-fields, group-and-count.

  * git — version control                                      :toolkit:
    :PROPERTIES:
    :ID:        git
    :CLI_BIN:   git
    :STATUS:    stable
    :SKILL_DIR: skills/
    :END:
    Recovery / rebase / undo recipes.
  """

  @doc "Toolkit-discovery demo (wb-11ck.46): `(tags :toolkit:)` + resolve an agent's :TOOLKITS:."
  def demo_toolkits do
    %{
      discovered: Workbooks.WorkKits.discover(@context_tree) |> Enum.map(& &1.id),
      workhorse_resolves: Workbooks.WorkKits.resolve(@context_tree, "workhorse") |> Enum.map(&{&1.id, &1.cli})
    }
  end

  @doc "Toolkit→command vertical: resolve the `text` toolkit and run its CLI (`upper`) as a WASM command."
  def demo_toolkit_run do
    {:ok, out} = Workbooks.WorkKits.run(@context_tree, "text", "hello from a toolkit")
    %{toolkit: "text", cli: "upper", output: out}
  end

  @doc "On-disk toolkit demo: discover toolkits/text/ (manifest.org + skills/) from disk."
  def demo_toolkit_disk do
    tks = Workbooks.WorkKits.discover_dir("toolkits")
    text = Enum.find(tks, &(&1.id == "text"))

    %{
      discovered: Enum.map(tks, & &1.id),
      text_cli: text && text.cli,
      text_dir: text && text.dir,
      skills_on_disk: text && Workbooks.WorkKits.skills(text.dir)
    }
  end

  @doc "Command-registry demo (wb-11ck.21): a component invokes `run-command(\"upper\", ...)` through the Dock."
  def demo_commands do
    id = "cmd-#{System.unique_integer([:positive])}"
    bytes = File.read!("build/fixtures/engine-probe.wasm")
    {:ok, _} = Workbooks.Instance.Supervisor.start_instance(id, bytes, policy: :minimal)
    {:ok, ran} = Workbooks.Instance.call(id, "run", ["command"])
    %{registry: Workbooks.CommandRegistry.list(), command_output: Jason.decode!(ran)["command"]}
  end

  @doc "Bundle egress demo (wb-11ck.29): ship a Workbook to a portable .wbundle, restore it, reopen the VFS."
  def demo_bundle do
    id = "ship-#{System.unique_integer([:positive])}"
    db = Path.join(System.tmp_dir!(), "#{id}.sqlite")
    {:ok, conn} = Workbooks.VFS.open(db)
    Workbooks.VFS.put(conn, "/state", "carried across the wire", "memory")
    Exqlite.Sqlite3.close(conn)

    blob = Workbooks.Bundle.ship(id, "<h1>Workbook</h1>", File.read!(db))
    {manifest, html, vfs_bytes} = Workbooks.Bundle.restore(blob)

    out = Path.join(System.tmp_dir!(), "#{id}-restored.sqlite")
    File.write!(out, vfs_bytes)
    {:ok, r} = Workbooks.VFS.open(out)
    %{bundle_bytes: byte_size(blob), manifest: manifest, html: html, restored_memory: Workbooks.VFS.get(r, "/state", "memory")}
  end

  @doc "Litestream durability demo (wb-11ck.19): replicate an Instance VFS to a file replica, then restore intact."
  def demo_litestream do
    dir = Path.join(System.tmp_dir!(), "ls-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    db = Path.join(dir, "vfs.db")
    replica = "file://" <> Path.join(dir, "replica")

    {:ok, conn} = Workbooks.VFS.open(db)
    Workbooks.Litestream.enable_wal(conn)
    Enum.each(1..3, &Workbooks.VFS.put(conn, "/n#{&1}", "row #{&1}"))

    port = Workbooks.Litestream.replicate(db, replica)
    Process.sleep(3000)
    Workbooks.Litestream.stop(port)

    out = Path.join(dir, "restored.db")
    {:ok, _} = Workbooks.Litestream.restore(replica, out)
    {:ok, r} = Workbooks.VFS.open(out)
    %{replica_url: replica, restored_n2: Workbooks.VFS.get(r, "/n2"), restored_rows: Workbooks.VFS.query_json(r, "SELECT count(*) FROM vfs")}
  end
end
