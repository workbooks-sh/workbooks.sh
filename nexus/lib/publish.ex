defmodule Nexus.Publish do
  @moduledoc """
  The agent-reachable SHIP path (wb-jr1py.11 + wb-jr1py.13) — publish a managed `facet app`
  surface to the edge, THROUGH the autopoiesis authority model, never around it.

  Authorization chain (each step fail-closed, reasons explicit):

    1. the caller has an agent IDENTITY (perms carry `agent` — a bare run can't own anything);
    2. the agent's `grant` includes `publish` (capability vocabulary, `Nexus.Capabilities`);
    3. the surface exists in the tree and declares `facet app` (`Nexus.Facet`);
    4. the agent OWNS it — the `manages` binding (`Nexus.Facet.owner/2`);
    5. the agent's `management` posture: `managed` → autonomous (already ceiling-scoped);
       `proposed` → refused with the request-lane pointer; `frozen` → refused.

  SHIP = `Nexus.Export` bundle → object store (`Nexus.S3`, the `asset-store` location, keys under
  `apps/<tenant>/<surface>/`) → an ES-module worker serving the bundle from an R2 BINDING
  (`Nexus.Cloudflare.upload_worker`) + workers.dev subdomain — the per-app EDGE deployment: the
  app product lives at the edge (zero-egress bytes), the agent at origin manages it. Hybrid
  bundles proxy `/data /live /ws /api` back to the origin nexus from the worker.

  Contract: `{:ok, result} | {:refused, reason} | {:skip, reason} | {:error, reason}` —
  `refused` is an AUTHORIZATION verdict, `skip` means the edge seams are dark (no store/CF); the
  export still ran locally on skip so the failure mode is honest and inspectable.
  """
  require Logger

  @doc "Publish `surface` (relative path) of the tree at `root`, as the agent in `perms`."
  def publish(root, surface, perms, opts \\ []) do
    surface = surface |> to_string() |> String.trim("/")
    agent = is_map(perms) && perms[:agent] && to_string(perms[:agent])
    grant = (is_map(perms) && perms[:grant]) || []
    posture = (is_map(perms) && perms[:management]) || "managed"
    tenant = (is_map(perms) && perms[:tenant]) || "default"
    dir = Path.join(root, surface)

    cond do
      agent in [nil, ""] ->
        {:refused, "publish needs an agent identity — only a declared agent can own an app"}

      "publish" not in List.wrap(grant) ->
        {:refused, "the `publish` capability is not granted to agent :#{agent} (structural triad: a human adds `grant publish`)"}

      not File.dir?(dir) ->
        {:refused, "no surface \"#{surface}\" in this tree"}

      Nexus.Facet.facet(dir) != "app" ->
        {:refused, "\"#{surface}\" is not a `facet app` surface — only app products ship (facet: #{Nexus.Facet.facet(dir) || "undeclared"})"}

      (owner = Nexus.Facet.owner(root, surface)) == nil or owner.agent != agent ->
        {:refused, ownership_reason(surface, agent, owner)}

      posture == "frozen" ->
        {:refused, "agent :#{agent} is `frozen` — it may not ship"}

      posture == "proposed" ->
        {:refused, "agent :#{agent} is `proposed` — route it through the human gate: `request self publish #{surface}`"}

      true ->
        ship(dir, surface, tenant, opts)
    end
  end

  defp ownership_reason(surface, agent, nil),
    do: "no agent manages \"#{surface}\" — declare `manages \"#{surface}\"` on the owning agent"

  defp ownership_reason(surface, agent, owner),
    do: "agent :#{agent} does not manage \"#{surface}\" (owner: :#{owner.agent})"

  # ── ship: export → R2 → worker ────────────────────────────────────────────────────────────────
  defp ship(dir, surface, tenant, opts) do
    out = Path.join(System.tmp_dir!(), "wb-publish-#{:erlang.unique_integer([:positive])}")

    export_opts =
      case opts[:origin] do
        origin when is_binary(origin) and origin != "" -> [mode: :hybrid, origin: origin]
        _ -> [mode: :static, tenant: tenant]
      end

    try do
      case Nexus.Export.surface(dir, out, export_opts) do
        {:ok, manifest} -> deploy(out, manifest, surface, tenant, opts)
        {:error, reason} -> {:error, {:export, reason}}
      end
    after
      File.rm_rf(out)
    end
  end

  defp deploy(out, manifest, surface, tenant, opts) do
    with {:ok, loc} <- store_loc(),
         {:ok, uploaded} <- upload_bundle(out, loc, tenant, surface) do
      worker = worker_name(tenant, surface)
      js = worker_js(loc, tenant, surface, manifest)

      meta = %{
        "compatibility_date" => "2026-01-01",
        "bindings" => [%{"type" => "r2_bucket", "name" => "ASSETS", "bucket_name" => loc.bucket}]
      }

      cf = Keyword.take(opts, [:cf_http, :cf_token, :cf_account]) |> rename_cf()

      case Nexus.Cloudflare.upload_worker(worker, js, [{:metadata, meta} | cf]) do
        {:ok, _} ->
          _ = Nexus.Cloudflare.enable_worker_subdomain(worker, cf)
          url = worker_url(worker)
          record(tenant, surface, worker, url, manifest)
          {:ok, %{worker: worker, url: url, pages: length(manifest.pages), assets: uploaded, mode: manifest.mode}}

        {:skip, reason} ->
          {:skip, "bundle exported + stored (#{uploaded} object(s)) but the worker seam is dark: #{reason}"}

        {:error, reason} ->
          {:error, {:worker, reason}}
      end
    end
  end

  # The bundle store = the SAME `asset-store` object-store location `Nexus.Assets` uses (declared
  # once in deploy) — app bundles live under their own `apps/…` prefix inside it.
  defp store_loc do
    case Nexus.Config.asset_store() do
      "s3://" <> rest -> parse_loc(rest)
      "r2://" <> rest -> parse_loc(rest)
      _ -> {:skip, "no asset-store declared (deploy asset-store=\"s3://bucket/prefix\") — nowhere to put the bundle"}
    end
  end

  defp parse_loc(rest) do
    if s3().configured?() do
      {bucket, prefix} =
        case String.split(rest, "/", parts: 2) do
          [b, p] -> {b, p}
          [b] -> {b, ""}
        end

      {:ok,
       %{
         bucket: bucket,
         prefix: prefix,
         endpoint: Nexus.Config.asset_store_endpoint(),
         region: Nexus.Config.asset_store_region()
       }}
    else
      {:skip, "object-store credentials absent (WB_S3_ACCESS_KEY_ID / AWS_ACCESS_KEY_ID)"}
    end
  end

  defp upload_bundle(out, loc, tenant, surface) do
    files = out |> Path.join("**/*") |> Path.wildcard() |> Enum.filter(&File.regular?/1)

    results =
      for f <- files do
        key = "#{app_key(tenant, surface)}/#{Path.relative_to(f, out)}"
        s3().put(loc, key, File.read!(f))
      end

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, length(results)}
      {:error, reason} -> {:error, {:upload, reason}}
    end
  end

  # Object keys are prefix-relative (`Nexus.S3` prepends the loc prefix).
  defp app_key(tenant, surface), do: "apps/#{safe(tenant)}/#{safe(surface)}"

  defp worker_name(tenant, surface), do: "wb-app-#{safe(tenant)}-#{safe(surface)}"

  defp worker_url(worker) do
    case Nexus.Config.cf_workers_subdomain() do
      sub when is_binary(sub) and sub != "" -> "https://#{worker}.#{sub}.workers.dev"
      _ -> nil
    end
  end

  # The full R2 object key includes the loc prefix — the worker reads the bucket directly.
  defp full_key(%{prefix: ""}, tail), do: tail
  defp full_key(%{prefix: p}, tail), do: "#{p}/#{tail}"

  defp worker_js(loc, tenant, surface, manifest) do
    prefix = full_key(loc, app_key(tenant, surface))
    origin = manifest.origin || ""
    proxy = Enum.map_join(manifest.proxy, ",", &~s("#{&1}"))

    """
    // Generated by Nexus.Publish — serves the exported bundle from the R2 binding; hybrid
    // dynamic paths proxy to the origin nexus. Regenerated on every publish.
    const PREFIX = #{inspect(prefix)};
    const ORIGIN = #{inspect(origin)};
    const PROXY = [#{proxy}];
    const TYPES = { html: "text/html; charset=utf-8", css: "text/css", js: "text/javascript",
      mjs: "text/javascript", svg: "image/svg+xml", png: "image/png", jpg: "image/jpeg",
      jpeg: "image/jpeg", webp: "image/webp", gif: "image/gif", ico: "image/x-icon",
      woff2: "font/woff2", woff: "font/woff", wasm: "application/wasm", txt: "text/plain",
      xml: "application/xml", pdf: "application/pdf", mp4: "video/mp4", mp3: "audio/mpeg" };

    export default {
      async fetch(req, env) {
        const url = new URL(req.url);
        if (ORIGIN && PROXY.some(p => url.pathname === p || url.pathname.startsWith(p + "/"))) {
          return fetch(ORIGIN + url.pathname + url.search, req);
        }
        let path = url.pathname;
        if (path.endsWith("/")) path += "index.html";
        else if (!path.split("/").pop().includes(".")) path += "/index.html";
        let obj = await env.ASSETS.get(PREFIX + path);
        if (!obj) obj = await env.ASSETS.get(PREFIX + "/404.html");
        if (!obj) return new Response("not found", { status: 404 });
        const ext = path.split(".").pop().toLowerCase();
        return new Response(obj.body, {
          headers: {
            "content-type": TYPES[ext] || "application/octet-stream",
            "cache-control": ext === "html" ? "public, max-age=0, must-revalidate" : "public, max-age=86400"
          }
        });
      }
    };
    """
  end

  # Deployment record — routing/identity only, a dynamic control-plane row (best-effort: a nexus
  # without the control plane still publishes fine).
  defp record(tenant, surface, worker, url, manifest) do
    Nexus.ControlPlane.put(tenant, :app_deploy, surface, %{
      worker: worker,
      url: url,
      mode: manifest.mode,
      pages: length(manifest.pages)
    })
  rescue
    _ -> :noop
  catch
    _, _ -> :noop
  end

  # CF client opts ride the same per-call injection convention as everywhere else.
  defp rename_cf(opts) do
    Enum.map(opts, fn
      {:cf_http, v} -> {:http, v}
      {:cf_token, v} -> {:token, v}
      {:cf_account, v} -> {:account, v}
    end)
  end

  defp s3, do: Application.get_env(:nexus, :publish_s3_client, Nexus.S3)

  defp safe(t) do
    case t |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9-]/, "-") |> String.trim("-") do
      "" -> "default"
      s -> String.slice(s, 0, 40)
    end
  end
end
