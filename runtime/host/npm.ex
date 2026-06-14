defmodule Workbooks.Npm do
  @moduledoc """
  In-sandbox npm registry resolver (wb-spy.T1.2) — the npm analog of the crates.io
  `resolve_via_index` path in `Workbooks.Compilers`. Given a package name and a semver
  range, it fetches the registry packument over verified-TLS `:httpc` (no curl) and
  selects the highest stable version satisfying the range. Returns the concrete version
  plus the production `dependencies` map and tarball URL so the T1.3 fetcher can recurse.

  Zero native execution: pure Elixir + `:httpc` + Jason. No `npm`/`node`/`curl` shelled.

  Range support is the node-semver subset that real-world deps actually use: exact,
  `^`, `~`, x-ranges (`1.x`, `1.2.x`, `1`, `1.2`), comparators (`>=`,`>`,`<=`,`<`,`=`),
  `||` unions, `*`/`""`/`latest`, and dist-tags (`latest`, `next`, `beta`, …).
  Prerelease versions are excluded unless the range itself names a prerelease.
  """

  @registry "https://registry.npmjs.org"

  @doc """
  Resolve `name`@`req` against the registry.

  Returns `{:ok, %{name, version, tarball, integrity, deps}}` where `deps` is the
  chosen version's production `dependencies` map (`%{dep_name => range}`), or
  `{:error, reason}`.
  """
  def resolve(name, req, _opts \\ []) do
    with {:ok, doc} <- fetch_packument(name),
         {:ok, version} <- pick_version(doc, req) do
      meta = get_in(doc, ["versions", version]) || %{}

      {:ok,
       %{
         name: name,
         version: version,
         tarball: get_in(meta, ["dist", "tarball"]),
         integrity: get_in(meta, ["dist", "integrity"]),
         deps: meta["dependencies"] || %{}
       }}
    end
  end

  @doc "Fetch + decode the full registry packument for `name`."
  def fetch_packument(name) do
    case https_get("#{@registry}/#{registry_path(name)}") do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, doc} when is_map(doc) -> {:ok, doc}
          _ -> {:error, {:packument_decode_failed, name}}
        end

      {:error, reason} ->
        {:error, {:registry_fetch_failed, name, String.slice(inspect(reason), 0, 150)}}
    end
  end

  # Scoped names (@scope/pkg) URL-encode the slash for the registry path.
  defp registry_path(name) do
    if String.starts_with?(name, "@"), do: String.replace(name, "/", "%2F"), else: name
  end

  # ── version selection ──────────────────────────────────────────────────────

  @doc """
  Pick the concrete version of a packument satisfying `req`. Exposed for testing.
  `doc` is the decoded packument; `req` a semver range or dist-tag.
  """
  def pick_version(doc, req) do
    req = String.trim(req || "")
    dist = doc["dist-tags"] || %{}
    versions = Map.keys(doc["versions"] || %{})

    cond do
      req in ["", "*", "x", "X", "latest"] and is_binary(dist["latest"]) ->
        {:ok, dist["latest"]}

      is_binary(dist[req]) ->
        {:ok, dist[req]}

      true ->
        allow_pre = String.contains?(req, "-")

        versions
        |> Enum.flat_map(fn v ->
          case parse(v) do
            {:ok, pv} -> [{v, pv}]
            _ -> []
          end
        end)
        |> Enum.reject(fn {_v, pv} -> pv.pre and not allow_pre end)
        |> Enum.filter(fn {_v, pv} -> satisfies?(pv.mmp, req) end)
        |> Enum.sort_by(fn {_v, pv} -> pv.mmp end, :desc)
        |> case do
          [{v, _} | _] -> {:ok, v}
          [] -> {:error, {:no_matching_version, req}}
        end
    end
  end

  @doc "Does version string `vsn` satisfy range `req`? Exposed for testing."
  def satisfies?(vsn, req) when is_binary(vsn) do
    case parse(vsn) do
      {:ok, pv} -> satisfies?(pv.mmp, req)
      _ -> false
    end
  end

  def satisfies?({_, _, _} = mmp, req) do
    req
    |> String.trim()
    |> String.split("||")
    |> Enum.any?(fn clause -> clause_matches?(mmp, clause) end)
  end

  defp clause_matches?(mmp, clause) do
    comps =
      clause
      |> String.split(~r/\s+/, trim: true)
      |> Enum.flat_map(&comparators/1)

    Enum.all?(comps, fn {op, target} -> cmp_op(mmp, op, target) end)
  end

  # One range token → list of {op, {maj,min,patch}} comparators ([] matches all).
  defp comparators(token) do
    token = String.trim(token)

    cond do
      token in ["", "*", "x", "X"] -> []
      String.starts_with?(token, "^") -> caret(strip(token, "^"))
      String.starts_with?(token, "~") -> tilde(strip(token, "~"))
      String.starts_with?(token, ">=") -> [{:gte, lower(strip(token, ">="))}]
      String.starts_with?(token, "<=") -> le(strip(token, "<="))
      String.starts_with?(token, ">") -> [{:gt, lower(strip(token, ">"))}]
      String.starts_with?(token, "<") -> [{:lt, lower(strip(token, "<"))}]
      String.starts_with?(token, "=") -> exact_or_range(strip(token, "="))
      true -> exact_or_range(token)
    end
  end

  defp strip(token, prefix), do: token |> String.replace_prefix(prefix, "") |> String.trim()

  # ^a.b.c ranges. Caret keeps the left-most non-zero component fixed.
  defp caret(t) do
    case parts(t) do
      {nil, _, _} -> []
      {a, b, c} when a > 0 -> [{:gte, {a, b || 0, c || 0}}, {:lt, {a + 1, 0, 0}}]
      {0, nil, _} -> [{:gte, {0, 0, 0}}, {:lt, {1, 0, 0}}]
      {0, b, c} when b > 0 -> [{:gte, {0, b, c || 0}}, {:lt, {0, b + 1, 0}}]
      {0, 0, nil} -> [{:gte, {0, 0, 0}}, {:lt, {0, 1, 0}}]
      {0, 0, c} -> [{:gte, {0, 0, c}}, {:lt, {0, 0, c + 1}}]
    end
  end

  # ~a.b.c ranges. Tilde allows patch-level (or minor when only major given) changes.
  defp tilde(t) do
    case parts(t) do
      {nil, _, _} -> []
      {a, nil, _} -> [{:gte, {a, 0, 0}}, {:lt, {a + 1, 0, 0}}]
      {a, b, c} -> [{:gte, {a, b, c || 0}}, {:lt, {a, b + 1, 0}}]
    end
  end

  # Bare token: full version → equality; partial / x-range → bounded window.
  defp exact_or_range(t) do
    case parts(t) do
      {nil, _, _} -> []
      {a, nil, _} -> [{:gte, {a, 0, 0}}, {:lt, {a + 1, 0, 0}}]
      {a, b, nil} -> [{:gte, {a, b, 0}}, {:lt, {a, b + 1, 0}}]
      {a, b, c} -> [{:eq, {a, b, c}}]
    end
  end

  # <= with a partial bound rounds up to an exclusive upper bound.
  defp le(t) do
    case parts(t) do
      {nil, _, _} -> []
      {a, nil, _} -> [{:lt, {a + 1, 0, 0}}]
      {a, b, nil} -> [{:lt, {a, b + 1, 0}}]
      {a, b, c} -> [{:lte, {a, b, c}}]
    end
  end

  # Lower bound for >=/>/<: missing components default to 0.
  defp lower(t) do
    {a, b, c} = parts(t)
    {a || 0, b || 0, c || 0}
  end

  # "1.2.3" → {1,2,3}; "1.2"/"1.2.x" → {1,2,nil}; "1"/"1.x" → {1,nil,nil}; "x"/"" → {nil,…}.
  defp parts(t) do
    segs = t |> String.split(".") |> Enum.map(&seg/1)
    {Enum.at(segs, 0), Enum.at(segs, 1), Enum.at(segs, 2)}
  end

  defp seg(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp cmp_op(mmp, :eq, t), do: mmp == t
  defp cmp_op(mmp, :gte, t), do: mmp >= t
  defp cmp_op(mmp, :gt, t), do: mmp > t
  defp cmp_op(mmp, :lte, t), do: mmp <= t
  defp cmp_op(mmp, :lt, t), do: mmp < t

  # Parse a semver version string → %{mmp: {maj,min,patch}, pre: bool}. Build metadata
  # (+…) is ignored; a prerelease (-…) sets pre: true (and is excluded by default).
  defp parse(v) do
    {core, pre?} =
      case String.split(v, "-", parts: 2) do
        [core, _pre] -> {core, true}
        [core] -> {String.split(core, "+", parts: 2) |> hd(), false}
      end

    core = core |> String.split("+", parts: 2) |> hd()

    case core |> String.split(".") |> Enum.map(&Integer.parse/1) do
      [{a, ""}, {b, ""}, {c, ""}] -> {:ok, %{mmp: {a, b, c}, pre: pre?}}
      _ -> :error
    end
  end

  # ── tarball fetch + transitive node_modules assembly (wb-spy.T1.3) ─────────
  # The npm analog of Workbooks.Compilers.fetch_crate, extended to walk the dependency
  # graph. Given the parsed top-level deps (from PackageManager.parse_package_json_deps),
  # resolve+fetch each from the registry, extract the gzipped .tgz with :erl_tar (no tar
  # binary), and lay out a FLAT (npm-v3-hoisted) node_modules/ tree under `dest`. First
  # version installed for a name wins (transitive duplicates are skipped). Pure Elixir.

  @doc """
  Assemble `dest/node_modules/` from top-level deps `[%{name, req, pin}]`. Returns
  `{:ok, installed}` (or `{:ok, installed, errors}` if some optional/transitive deps
  failed) where `installed` is `%{name => version}`.
  """
  def install_tree(deps, dest) when is_list(deps) do
    nm = Path.join(dest, "node_modules")
    File.mkdir_p!(nm)
    # package.json `overrides` force a version for a (possibly transitive) package — honored everywhere a
    # name is resolved (security pins / dedup). Only simple `name => version` string overrides are applied.
    overrides = read_overrides(dest)
    queue = Enum.map(deps, fn d -> {d.name, d.pin || d.req} end)
    install_loop(queue, nm, overrides, %{}, [])
  end

  defp read_overrides(dest) do
    with {:ok, body} <- File.read(Path.join(dest, "package.json")),
         {:ok, j} <- Jason.decode(body),
         o when is_map(o) <- j["overrides"] do
      for {k, v} <- o, is_binary(v), into: %{}, do: {k, v}
    else
      _ -> %{}
    end
  end

  @doc """
  Install the EXACT pinned tree from a lockfile in `dir` (npm `package-lock.json`; pnpm/yarn added per
  their own surfaces). Reproducible: every locked package installs at its pinned version — no fresh range
  resolution. Returns `install_tree/2`'s result, or `{:error, :no_lockfile}` / `{:error, {:unsupported_lockfile, _}}`.
  """
  def install_from_lockfile(dir) do
    case parse_lockfile(dir) do
      {:ok, specs} -> install_tree(specs, dir)
      err -> err
    end
  end

  @doc "Parse a lockfile in `dir` into pinned specs `[%{name, req: nil, pin: version}]`."
  def parse_lockfile(dir) do
    npm = Path.join(dir, "package-lock.json")

    cond do
      File.exists?(npm) -> parse_npm_lock(npm)
      File.exists?(Path.join(dir, "pnpm-lock.yaml")) -> parse_pnpm_lock(Path.join(dir, "pnpm-lock.yaml"))
      File.exists?(Path.join(dir, "yarn.lock")) -> parse_yarn_lock(Path.join(dir, "yarn.lock"))
      true -> {:error, :no_lockfile}
    end
  end

  # pnpm-lock.yaml (v6/v9): the `packages:`/`snapshots:` keys are `name@version` (optionally `/`-prefixed,
  # quoted, with a `(peer@x)` suffix). Pull name@version from each key — no YAML dep needed.
  defp parse_pnpm_lock(path) do
    specs =
      ~r/^  '?\/?(@?[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)?)@(\d[^:'\s(]*)/m
      |> Regex.scan(File.read!(path))
      |> Enum.map(fn [_, name, version] -> %{name: name, req: nil, pin: version} end)
      |> Enum.uniq_by(& &1.name)

    {:ok, specs}
  end

  # yarn.lock — classic (v1: `spec:` header + `  version "x"`) and berry (v2+: `"spec@npm:range":` +
  # `  version: x`). Track the current header; each version line pins the header's package.
  defp parse_yarn_lock(path) do
    {specs, _} =
      File.read!(path)
      |> String.split("\n")
      |> Enum.reduce({[], nil}, fn line, {acc, header} ->
        cond do
          Regex.match?(~r/^["']?\S.*:\s*$/, line) and String.contains?(line, "@") ->
            {acc, yarn_name_from_header(line)}

          (m = Regex.run(~r/^\s+version:?\s+"?(\d[^"\s]*)"?/, line)) && header ->
            {[%{name: header, req: nil, pin: hd(tl(m))} | acc], nil}

          true ->
            {acc, header}
        end
      end)

    {:ok, specs |> Enum.uniq_by(& &1.name) |> Enum.reverse()}
  end

  # First spec in a yarn header → package name. Handles scoped (@s/p), quotes, classic ranges, berry npm:.
  defp yarn_name_from_header(line) do
    spec =
      line |> String.trim() |> String.trim_trailing(":") |> String.split(",") |> List.first()
      |> String.trim() |> String.trim("\"")

    case String.split(spec, "@") do
      ["", scope_pkg | _] -> "@" <> scope_pkg
      [name | _] -> name
    end
  end

  # npm package-lock.json v2/v3: the "packages" map keys are node_modules paths; the LAST `node_modules/`
  # segment is the package name, `version` the pin. The root key "" and dev-only entries are skipped.
  defp parse_npm_lock(path) do
    with {:ok, doc} <- Jason.decode(File.read!(path)) do
      specs =
        for {key, meta} <- doc["packages"] || %{},
            key != "",
            is_map(meta),
            not (meta["dev"] == true),
            (v = meta["version"]) && is_binary(v) do
          name = key |> String.split("node_modules/") |> List.last()
          %{name: name, req: nil, pin: v}
        end
        |> Enum.uniq_by(& &1.name)

      {:ok, specs}
    end
  end

  defp install_loop([], _nm, _ov, installed, []), do: {:ok, installed}
  defp install_loop([], _nm, _ov, installed, errors), do: {:ok, installed, Enum.reverse(errors)}

  defp install_loop([{name, spec} | rest], nm, ov, installed, errors) do
    if Map.has_key?(installed, name) do
      install_loop(rest, nm, ov, installed, errors)
    else
      case install_one(name, Map.get(ov, name, spec), nm) do
        {:ok, version, child_deps} ->
          install_loop(rest ++ child_deps, nm, ov, Map.put(installed, name, version), errors)

        {:error, reason} ->
          install_loop(rest, nm, ov, installed, [reason | errors])
      end
    end
  end

  defp install_one(name, spec, nm) do
    with {:ok, version, tarball} <- resolve_target(name, spec),
         {:ok, pkgdir} <- fetch_tarball(name, version, tarball, nm) do
      {:ok, version, read_prod_deps(pkgdir)}
    end
  end

  # A pin (exact version) skips the packument fetch — the tarball URL is constructed
  # directly; a range is resolved against the registry.
  defp resolve_target(name, spec) do
    cond do
      exact_version?(spec) ->
        {:ok, spec, tarball_url(name, spec)}

      true ->
        case resolve(name, spec) do
          {:ok, %{version: v, tarball: t}} when is_binary(t) -> {:ok, v, t}
          {:ok, %{version: v}} -> {:ok, v, tarball_url(name, v)}
          err -> err
        end
    end
  end

  defp exact_version?(spec), do: spec =~ ~r/^\d+\.\d+\.\d+(-[\w.]+)?$/

  # npm tarball URL: scope is NOT %2F-encoded in this form, and the basename is the
  # unscoped package name. e.g. @scope/pkg@1.0.0 → .../@scope/pkg/-/pkg-1.0.0.tgz
  defp tarball_url(name, version) do
    base = name |> String.split("/") |> List.last()
    "#{@registry}/#{name}/-/#{base}-#{version}.tgz"
  end

  # Fetch + extract a .tgz into node_modules/<name>. The tarball's files live under a
  # top-level "package/" dir (npm convention); we relocate that to the install path.
  defp fetch_tarball(name, version, url, nm) do
    tmp = Path.join(nm, ".dl-#{:erlang.phash2({name, version})}")
    dest = Path.join(nm, name)
    File.rm_rf(tmp)
    File.mkdir_p!(tmp)
    tgz = Path.join(tmp, "p.tgz")

    result =
      with {:ok, body} <- https_get(url),
           :ok <- File.write(tgz, body),
           :ok <-
             :erl_tar.extract(String.to_charlist(tgz), [
               :compressed,
               {:cwd, String.to_charlist(tmp)}
             ]) do
        src = Path.join(tmp, "package")

        if File.dir?(src) do
          File.rm_rf(dest)
          File.mkdir_p!(Path.dirname(dest))
          File.cp_r!(src, dest)
          {:ok, dest}
        else
          {:error, {:no_package_dir, name, version}}
        end
      else
        {:error, reason} -> {:error, {:fetch_failed, name, version, brief(reason)}}
      end

    File.rm_rf(tmp)
    result
  end

  # The installed package's PRODUCTION dependencies (devDependencies are not installed
  # transitively), minus non-registry protocol specs.
  defp read_prod_deps(pkgdir) do
    pj = Path.join(pkgdir, "package.json")

    with {:ok, body} <- File.read(pj),
         {:ok, j} <- Jason.decode(body),
         true <- is_map(j),
         deps when is_map(deps) <- j["dependencies"] do
      Enum.flat_map(deps, fn
        {n, spec} when is_binary(spec) -> if npm_unfetchable?(spec), do: [], else: [{n, spec}]
        _ -> []
      end)
    else
      _ -> []
    end
  end

  # Specs the registry cannot fetch (protocol-prefixed / github shorthand) — same rule as
  # PackageManager.npm_unfetchable?/1, applied to transitive deps read off disk.
  defp npm_unfetchable?(spec) do
    spec =~ ~r{^(git\+|git:|file:|link:|workspace:|https?:|github:|[\w.-]+/[\w.-]+(#|$))}
  end

  defp brief(reason), do: reason |> inspect() |> String.slice(0, 200)

  # ── network ──────────────────────────────────────────────────────────────
  # Pure-Erlang HTTPS GET with verified TLS via the OS trust store — same shape as
  # Workbooks.Compilers.http_get (wb-ova). No curl binary.
  defp https_get(url) do
    :inets.start()
    :ssl.start()

    ssl_opts = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      depth: 3
    ]

    req = {String.to_charlist(url), []}
    http_opts = [ssl: ssl_opts, timeout: 30_000, connect_timeout: 15_000, autoredirect: true]

    case :httpc.request(:get, req, http_opts, body_format: :binary) do
      {:ok, {{_v, 200, _}, _headers, body}} -> {:ok, body}
      {:ok, {{_v, code, _}, _headers, _body}} -> {:error, {:http_status, code}}
      {:error, reason} -> {:error, reason}
    end
  end
end
