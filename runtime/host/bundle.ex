defmodule Workbooks.Bundle do
  @moduledoc """
  The Workbook egress format (wb-11ck.29): one portable `.wbundle` (a zip) holding
  the Workbook HTML, its SQLite VFS (all named volumes), and a manifest. Hand
  someone one file and they have the complete session — and because it's a plain
  zip, any tool can open it (not a BEAM-only term). ship → restore round-trips it;
  archiving is just writing the blob to cold storage / R2.
  """

  @doc ~S|Pack a parts map (%{"name" => binary}) into one zip blob.|
  def pack(parts) when is_map(parts) do
    files = Enum.map(parts, fn {k, v} -> {String.to_charlist(k), v} end)
    {:ok, {_name, zip}} = :zip.create(~c"workbook.wbundle", files, [:memory])
    zip
  end

  # Zip-bomb / decompression-ratio guard (the inferred security floor). A few-KB
  # base64 zip can inflate to gigabytes and OOM the host BEAM (`:zip.extract`), the
  # agent sandbox, or — via the JS loader — a browser tab. So we cap the TOTAL
  # decompressed size AND each entry's expansion RATIO, refusing BEFORE the runaway
  # output is fully materialized in the caller. The JS loader mirrors these caps.
  @max_total_bytes 512 * 1024 * 1024
  @max_ratio 200

  @doc """
  Unpack a Bundle blob back to its parts map. Guards against zip-bombs: rejects a
  blob whose entries together exceed `#{@max_total_bytes}` bytes uncompressed, or
  any single entry that expands beyond `#{@max_ratio}×` its compressed size. Raises
  `ArgumentError` on a bomb rather than letting decompression run away.
  """
  def unpack(blob) when is_binary(blob) do
    guard_zip_bomb!(blob)
    {:ok, files} = :zip.extract(blob, [:memory])
    Map.new(files, fn {name, content} -> {List.to_string(name), content} end)
  end

  # Read the central directory's declared sizes (authoritative; cheap, no inflate)
  # and reject before extraction if the bomb thresholds are crossed. We use the
  # per-entry compressed/uncompressed pair from `:zip.list_dir` so a single
  # high-ratio entry is caught even when the total stays modest.
  defp guard_zip_bomb!(blob) do
    {:ok, entries} = :zip.list_dir(blob)

    {total, _} =
      Enum.reduce(entries, {0, 0}, fn
        {:zip_file, _name, info, _comment, _offset, comp_size}, {total, _} ->
          uncomp = elem(info, 1)

          if comp_size > 0 and uncomp > comp_size * @max_ratio do
            raise ArgumentError, "bundle entry exceeds #{@max_ratio}× expansion (zip-bomb guard)"
          end

          {total + uncomp, comp_size}

        _other, acc ->
          acc
      end)

    if total > @max_total_bytes do
      raise ArgumentError, "bundle exceeds #{@max_total_bytes}B uncompressed (zip-bomb guard)"
    end

    :ok
  end

  @doc ~S"""
  Read a directory tree into a parts map (`%{"relative/path" => binary}`), the
  inverse of writing `unpack/1` back to disk. Keys are forward-slash relative
  paths from `dir`; private + VCS noise (`.git`, agent memory/tmp) is stripped so
  a bundled tree carries the working files, not the session. One home for the
  tree↔map mapping the CLI `bundle` verb needs.
  """
  def read_tree(dir) when is_binary(dir) do
    root = Path.expand(dir)

    root
    |> ls_r()
    |> Enum.reject(&strip_path?/1)
    |> Map.new(fn abs ->
      rel = abs |> Path.relative_to(root) |> String.replace("\\", "/")
      {rel, File.read!(abs)}
    end)
  end

  defp ls_r(path) do
    cond do
      File.regular?(path) ->
        [path]

      File.dir?(path) ->
        path
        |> File.ls!()
        |> Enum.flat_map(&ls_r(Path.join(path, &1)))

      true ->
        []
    end
  end

  # VCS internals and per-session private state never belong in a portable tree.
  # Consults the ONE public/private boundary (`Workbooks.Private`) so the raw-tree
  # `wb bundle <dir>` egress strips secrets / agent-memory / session sidecars the
  # SAME way every other egress (Git, Library) does — a shared `.html` carries the
  # work, never the session that made it.
  defp strip_path?(abs) do
    parts = Path.split(abs)

    Enum.any?([".git", ".beads", "node_modules", "_build", ".tmp", ".private"], &(&1 in parts)) or
      Workbooks.Private.private?(abs)
  end

  @doc ~S"""
  Write an unpacked parts map to `dir`, path-confined: any entry that is absolute
  or escapes `dir` via `..` is rejected (mirrors the CLI `with_org_file` guard) so
  a hostile bundle can't write outside its target tree. Returns the count written.
  """
  def write_tree(parts, dir) when is_map(parts) and is_binary(dir) do
    root = Path.expand(dir)

    for {name, content} <- parts do
      p = Path.expand(Path.join(dir, name))

      unless safe_member?(name) and String.starts_with?(p <> "/", root <> "/") do
        raise ArgumentError, "unsafe bundle path: #{name}"
      end

      File.mkdir_p!(Path.dirname(p))
      File.write!(p, content)
    end

    map_size(parts)
  end

  defp safe_member?(name) do
    name != "" and Path.type(name) == :relative and
      ".." not in Path.split(name)
  end

  @doc """
  Ship a Workbook for egress: bundle its HTML + VFS (the single SQLite file
  carrying every named volume) + a manifest. Returns the `.wbundle` blob.

  Sealed-bundle ("rzip", wb-v3w): pass `gated: ["secret.html", ...]` to SEAL those
  entries. A sealed entry is AES-256-GCM ciphertext; its content key is escrowed at
  the runtime (`Workbooks.Bundle.Escrow`) and the manifest carries only a
  `key_refs` reference (`path → %{key_id, algo}`), NEVER the key. Public entries
  stay plaintext. The runtime releases a key only after `Workbooks.Access.enforce`
  passes (`POST /rcp/key/:key_id`), so the gated bytes are noise to anyone who has
  the bundle but not a posture-approved release.

  Egress form (the migration): `egress: :html` (DEFAULT) returns the self-contained
  `.html` — the packed filesystem (vfs + manifest + sealed entries, NOT a second
  copy of the page) embedded INTO the signed page html. `egress: :wbundle` returns
  the legacy raw zip (workbook.html + vfs + manifest packed) for back-compat.

  Provenance over the embedded form: the page is signed with the wb-bundle block
  stripped (so embed/extract don't move the signed bytes — `Manifest` does the
  strip), and the embedded zip blob is bound by a signed `wb.bundle.sha256`
  assertion. So a swapped payload under a valid-looking signature fails `verify/1`.
  """
  def ship(id, html, vfs_bytes, opts \\ []) when is_binary(vfs_bytes) do
    # Privacy by default: a shared bundle carries the working tree, NOT the
    # session that made it — agent memory + tmp are stripped unless the owner
    # explicitly opts in. One boundary (`Workbooks.Private`) for every egress.
    vfs_bytes = if opts[:include_private], do: vfs_bytes, else: Workbooks.VFS.public_only(vfs_bytes)

    base_manifest = %{
      "id" => id,
      "format" => if(Keyword.get(opts, :egress, :html) == :html, do: "wbundle-html/1", else: "wbundle/1"),
      "volumes" => if(opts[:include_private], do: Workbooks.VFS.volumes(), else: Workbooks.Private.public_volumes()),
      "private_included" => !!opts[:include_private],
      "created" => System.system_time(:second)
    }

    case Keyword.get(opts, :egress, :html) do
      :wbundle -> ship_wbundle(id, html, vfs_bytes, base_manifest, opts)
      _ -> ship_html(id, html, vfs_bytes, base_manifest, opts)
    end
  end

  # Legacy egress: the page + vfs + manifest packed into one raw zip blob.
  defp ship_wbundle(id, html, vfs_bytes, manifest, opts) do
    {html, signed} = maybe_sign(html, opts[:tenant])
    parts = %{"workbook.html" => html, "vfs.sqlite" => vfs_bytes}
    {parts, key_refs} = seal_gated(parts, opts[:gated], id)
    manifest = manifest |> Map.put("signed", signed) |> put_key_refs(key_refs)
    pack(Map.put(parts, "manifest.json", Jason.encode!(manifest)))
  end

  # Self-contained egress: pack the filesystem (vfs + manifest + sealed entries —
  # the page is the carrier, NOT packed), embed into the page, then sign the page
  # binding the embedded zip's sha. Order is deliberate: blob sha is known BEFORE
  # signing (no circularity), and the sign strips the wb-bundle block when hashing.
  defp ship_html(id, html, vfs_bytes, manifest, opts) do
    parts = %{"vfs.sqlite" => vfs_bytes}
    {parts, key_refs} = seal_gated(parts, opts[:gated], id)
    manifest = manifest |> Map.put("signed", !!opts[:tenant]) |> put_key_refs(key_refs)

    blob = pack(Map.put(parts, "manifest.json", Jason.encode!(manifest)))
    page = embed(html, blob)

    case opts[:tenant] do
      nil ->
        page

      t ->
        assertions = [
          %{"type" => "c2pa.action.published", "actor" => Workbooks.Git.did(t)},
          bundle_sha_assertion_for(blob)
        ]

        Workbooks.Manifest.sign(page, t, assertions)
    end
  end

  defp maybe_sign(html, nil), do: {html, false}

  defp maybe_sign(html, t),
    do: {Workbooks.Manifest.sign(html, t, [%{"type" => "c2pa.action.published", "actor" => Workbooks.Git.did(t)}]), true}

  defp put_key_refs(manifest, key_refs) when map_size(key_refs) == 0, do: manifest
  defp put_key_refs(manifest, key_refs), do: Map.put(manifest, "key_refs", key_refs)

  # Seal the gated paths via the runtime escrow keyfn, annotating each ref with the
  # AEAD algo (the manifest stays self-describing for any opener / the client).
  defp seal_gated(parts, gated, id) when is_list(gated) and gated != [] do
    keyfn = Workbooks.Bundle.Escrow.keyfn(to_string(id))
    {sealed, refs} = Workbooks.Bundle.Sealed.seal_entries(parts, gated, keyfn)
    refs = Map.new(refs, fn {path, ref} -> {path, Map.put(ref, "algo", "aes-256-gcm")} end)
    {sealed, refs}
  end

  defp seal_gated(parts, _none, _id), do: {parts, %{}}

  # ── Tangle: org → native source (the compile step's input materialization) ──
  #
  # The lifecycle's "tangle + compile" stage (docs/WORKBOOK-BUNDLE.md). The org
  # file is the source-of-truth; its `:component:` code blocks are the native
  # source. `tangle_files/1` is the org→native EMITTER alongside the kernel's
  # plan-only `OQL.tangle_plan` — it REUSES that plan (no kernel rebuild) and
  # writes each component's `src` body to its native file on disk, so the
  # in-sandbox compiler lanes (Workbooks.Build → PackageManager/Compilers) can
  # discover + compile them. One direction of the literate loop: org re-tangles
  # to native on every rebuild, so editing the org (or re-tangled native) and
  # re-bundling stays consistent — the bundle never carries stale tangled source.

  # Map a component's org source language to its native file extension. Mirrors
  # the lanes Workbooks.Build discovers (a lone `.rs`, a C/Zig leaf, a JS entry).
  @lang_ext %{
    "rust" => ".rs",
    "rs" => ".rs",
    "c" => ".c",
    "zig" => ".zig",
    "javascript" => ".js",
    "js" => ".js",
    "typescript" => ".ts",
    "ts" => ".ts"
  }

  @doc ~S"""
  Tangle the org source-of-truth in `parts` to native source files, returning the
  parts map with each `:component:` block's body materialized at
  `<dir>/<name><ext>` (the tangle direction org→native). REUSES `OQL.tangle_plan`
  — the same WIT-world build plan the kernel already emits — rather than
  reparsing org. A part already present at a tangled path is OVERWRITTEN (the org
  is canonical; re-tangle wins) so the lifecycle's "edit source not compiled wasm"
  invariant holds: the org round-trips, native is always derived.

  `org` defaults to `parts["source.org"] || parts["workbook.org"]` — the same org
  lookup the `bundle` CLI verb renders from. With no org, parts pass through
  unchanged (a non-literate tree has nothing to tangle).
  """
  def tangle_files(parts, org \\ nil) when is_map(parts) do
    org = org || parts["source.org"] || parts["workbook.org"]

    if is_binary(org) and org != "" do
      plan = Workbooks.OQL.tangle_plan(org)

      plan
      |> plan_components()
      |> Enum.reduce(parts, fn comp, acc ->
        case tangled_path(comp) do
          nil -> acc
          path -> Map.put(acc, path, comp["src"] || "")
        end
      end)
    else
      parts
    end
  end

  # Flatten the nested plan (worlds → components, workflows → sub-worlds) to a
  # flat component list — the tangle target is every leaf component, at any depth.
  defp plan_components(%{"worlds" => worlds}) when is_list(worlds),
    do: Enum.flat_map(worlds, &world_components/1)

  defp plan_components(_), do: []

  defp world_components(%{} = world) do
    comps = Map.get(world, "components", []) || []
    subs = Map.get(world, "workflows", []) || []
    comps ++ Enum.flat_map(subs, &world_components/1)
  end

  # The native path a component tangles to: `<dir>/<name><ext>`. A component with
  # no recognized language (no source block / unknown lang) has no native file —
  # skipped, same posture as the kernel's validate (a langless component is a
  # diagnostic, not a tangle target).
  defp tangled_path(%{"name" => name, "lang" => lang} = comp)
       when is_binary(name) and name != "" do
    case @lang_ext[lang && String.downcase(lang)] do
      nil ->
        nil

      ext ->
        slug = name |> String.replace(~r/[^\w.\-]+/, "-") |> String.trim("-")
        file = slug <> ext

        case comp["dir"] do
          d when is_binary(d) and d != "" -> Path.join(d, file)
          _ -> file
        end
    end
  end

  defp tangled_path(_), do: nil

  @doc ~S"""
  Compile a working tree's native source → `.wasm` and return the parts map with
  those compiled outputs MERGED in (the lifecycle's "compile" stage). REUSES
  `Workbooks.Build.build/1` — the same in-sandbox lane driver (PackageManager /
  Compilers: mrustc.wasm→clang.wasm for Rust, C/Zig, js_compile_to_wasm) behind
  `Library.build_projection` — by materializing parts to a throwaway tree, never
  re-deriving the compile loop. A built component lands as `<name>.wasm` (the same
  shape `Library.install/3` registers via CommandRegistry).

  `build: false` skips compilation (source-only pack); the org source + tangled
  native still ship so the bundle stays re-editable. The native source INPUTS are
  kept alongside the `.wasm` (archive projection) — the bundled `.html` is the
  source-of-truth carrier, not just a runnable; org re-tangles on each rebuild.
  """
  def compile_tree(parts, opts \\ []) when is_map(parts) do
    if Keyword.get(opts, :build, true) and has_buildable?(parts) do
      tmp = Path.join(System.tmp_dir!(), "wb-bundle-compile-#{:erlang.unique_integer([:positive])}")
      File.rm_rf!(tmp)

      try do
        Enum.each(parts, fn {name, content} ->
          p = Path.join(tmp, name)
          File.mkdir_p!(Path.dirname(p))
          File.write!(p, content)
        end)

        report = Workbooks.Build.build(tmp)
        wasm = Map.new(report.built, fn b -> {b.name <> ".wasm", b.bytes} end)
        Map.merge(parts, wasm)
      after
        File.rm_rf(tmp)
      end
    else
      parts
    end
  end

  # Anything Workbooks.Build can discover (a Rust crate / lone .rs / a JS project)
  # — gate the temp-tree + lane spin-up on there being something to compile so a
  # plain doc tree never pays the cost.
  defp has_buildable?(parts) do
    Enum.any?(parts, fn {name, _} ->
      Path.extname(name) == ".rs" or Path.basename(name) in ~w(Cargo.toml package.json)
    end)
  end

  @doc ~S"""
  The back-compat dispatcher: given either egress FORM, return the raw zip blob.
  A legacy `.wbundle` is already a raw zip (starts with the local-file-header magic
  `PK\x03\x04`) — passed through. The new self-contained `.html` carries the zip in
  a `wb-bundle` <script> block — `extract`ed first. So `restore`/`open`/`verify`/
  `install`/`unpack` all accept BOTH forms transparently; no flag-day, old
  artifacts keep opening. Raises if it's neither.
  """
  def read_any(input) when is_binary(input) do
    case input do
      "PK" <> _ ->
        input

      _ ->
        case extract(input) do
          nil -> raise ArgumentError, "not a wbundle: neither a zip nor an html with a wb-bundle block"
          blob -> blob
        end
    end
  end

  @doc ~S"""
  Restore a Bundle (either form) → {manifest, workbook_html, vfs_sqlite_bytes}.

  Legacy `.wbundle`: the zip packs `workbook.html` + `vfs.sqlite` + `manifest.json`.
  Self-contained `.html`: the PAGE itself is the workbook_html (carrier), and the
  embedded zip packs the filesystem (`vfs.sqlite` + `manifest.json` + working files)
  WITHOUT a second copy of the page — so there's no circular self-embedding.
  """
  def restore(input) when is_binary(input) do
    if embedded?(input) do
      parts = unpack(extract(input))
      {Jason.decode!(parts["manifest.json"] || "{}"), input, parts["vfs.sqlite"]}
    else
      parts = unpack(read_any(input))
      {Jason.decode!(parts["manifest.json"]), parts["workbook.html"], parts["vfs.sqlite"]}
    end
  end

  @doc """
  Open a shipped bundle's sealed entries, releasing keys through `provider`
  (`key_id -> {:ok, key} | {:error, reason}`). Public entries pass through; a
  denied release surfaces as `{:error, {path, reason}}` — the gate holds. Returns
  `{:ok, parts}` (all entries plaintext) or that error. With no `key_refs` in the
  manifest this is just `unpack/1`.
  """
  def open(input, provider) when is_binary(input) and is_function(provider, 1) do
    parts = unpack(read_any(input))
    manifest = Jason.decode!(parts["manifest.json"])
    Workbooks.Bundle.Sealed.open_entries(parts, manifest["key_refs"] || %{}, provider)
  end

  @doc ~S"""
  Verify a shipped bundle's embedded provenance (signature + asset integrity over
  the workbook html). Accepts BOTH egress forms (`read_any/1`). For the
  self-contained `.html` egress the signature is over the page with the wb-bundle
  block stripped (`Manifest` does the strip), and the embedded zip is bound by the
  signed `bundle_sha256` assertion — so verify is stable across embed/extract and a
  swapped payload under a valid-looking signature is caught here.
  """
  def verify(input) when is_binary(input) do
    if embedded?(input) do
      # Self-contained `.html`: the PAGE is the carrier. Its signature (over the
      # page sans wb-bundle, via Manifest) plus the signed `wb.bundle.sha256`
      # assertion binding the embedded zip blob = tamper-evident over (page+fs).
      base = Workbooks.Manifest.verify(input)
      bind_bundle_integrity(base, extract(input))
    else
      # Legacy raw-zip `.wbundle`: provenance lives in the packed workbook.html.
      Workbooks.Manifest.verify(unpack(read_any(input))["workbook.html"] || "")
    end
  end

  # Bind signature ⇄ embedded filesystem: if the signed manifest pinned the zip blob
  # (a `wb.bundle.sha256` assertion the embedded-form ship adds), the actual blob's
  # sha must match — else a recipient could swap the wb-bundle payload under an
  # otherwise-valid signature. No such assertion → the base verdict stands.
  defp bind_bundle_integrity(%{valid: true} = base, blob) when is_binary(blob) do
    case bundle_sha_assertion(base[:assertions]) do
      nil ->
        base

      expected ->
        actual = :crypto.hash(:sha256, blob) |> Base.encode16(case: :lower)
        if actual == expected, do: base, else: Map.put(%{base | valid: false}, :bundle_integrity, false)
    end
  end

  defp bind_bundle_integrity(base, _blob), do: base

  defp bundle_sha_assertion(assertions) when is_list(assertions) do
    Enum.find_value(assertions, fn
      %{"type" => "wb.bundle.sha256", "value" => v} -> v
      _ -> nil
    end)
  end

  defp bundle_sha_assertion(_), do: nil

  @doc ~S"""
  The signed assertion that binds the embedded zip blob into the manifest. Added
  to `Manifest.sign`'s assertions when shipping the self-contained `.html` egress,
  so `verify/1` can confirm the payload wasn't swapped under a valid signature.
  """
  def bundle_sha_assertion_for(blob) when is_binary(blob) do
    %{"type" => "wb.bundle.sha256", "value" => :crypto.hash(:sha256, blob) |> Base.encode16(case: :lower)}
  end

  # ── The self-contained Workbook: the bundle lives INSIDE the .html ──────────
  #
  # The canonical portable Workbook is ONE .html that carries its filesystem as an
  # embedded bundle: the `pack/1` zip (already deflate-compressed per entry),
  # base64'd into a single `<script id="wb-bundle">` block. So one file is the page
  # AND its compressed data store — move it, archive it, serve it, all as one file.
  # base64's alphabet excludes `<`, so the payload can never break out of the
  # script tag (no escaping needed, injection-inert). Every tier unpacks the SAME
  # bytes: a browser via `DecompressionStream('deflate-raw')` per zip entry; the
  # host via `:zip`/`unpack/1`; the agent's sandbox via the wasm zip lane.

  @bundle_open ~s(<script type="application/zip" id="wb-bundle" data-encoding="base64">)
  @bundle_re ~r/<script[^>]*id="wb-bundle"[^>]*>(.*?)<\/script>/s

  # The browser loader's ONE home is the static asset web/wb-bundle-loader.js (the
  # tier that serves over HTTP references it; node --test unit-tests it). Compiled
  # in here via @external_resource so `embed_loader/1` can inline the SAME source
  # into a self-contained offline .html — no second copy to drift.
  @loader_path Path.join(__DIR__, "../../web/wb-bundle-loader.js")
  @external_resource @loader_path
  @loader_src File.read!(@loader_path)
  @loader_re ~r/<script[^>]*id="wb-bundle-loader"[^>]*>.*?<\/script>/s

  @doc """
  Embed a bundle blob INTO a workbook html — the self-contained form. Idempotent:
  any prior embedded bundle is replaced first, so re-bundling after edits stays
  clean. Injected just before `</body>` (or appended when there's no body).
  """
  def embed(html, blob) when is_binary(html) and is_binary(blob) do
    block = @bundle_open <> Base.encode64(blob) <> "</script>"
    html = strip_bundle(html)

    if String.contains?(html, "</body>"),
      do: String.replace(html, "</body>", block <> "\n</body>", global: false),
      else: html <> "\n" <> block
  end

  @doc """
  Inject the browser hydration loader INTO a workbook html so the page is
  self-contained offline (open the .html with `file://`, no server). Idempotent:
  any prior loader block is replaced. The classic-script form (module `export`s
  stripped) auto-runs on DOM ready, reads `wb-bundle`, inflates each zip entry via
  `DecompressionStream('deflate-raw')`, and dispatches `wb:hydrated`. Injected just
  before `</body>` (or appended). Served pages MAY instead reference the static
  asset `/wb-bundle-loader.js`; this is the offline / CLI-built path.
  """
  def embed_loader(html) when is_binary(html) do
    block = loader_block()
    html = Regex.replace(@loader_re, html, "", global: true)

    if String.contains?(html, "</body>"),
      do: String.replace(html, "</body>", block <> "\n</body>", global: false),
      else: html <> "\n" <> block
  end

  @doc "True when the html carries the inline hydration loader."
  def has_loader?(html) when is_binary(html), do: Regex.match?(@loader_re, html)

  @doc """
  The inline classic-script form of the static-asset loader: strips ESM `export `
  (no `import` in the source) so it runs without `type=module` from `file://`.
  The served-page shell (`PublicWeb.static_doc`) injects this directly; offline
  CLI-built pages get it via `embed_loader/1`. ONE rendition of the loader.
  """
  def loader_block do
    classic = String.replace(@loader_src, ~r/^export /m, "")
    ~s(<script id="wb-bundle-loader">\n) <> classic <> "\n</script>"
  end

  @doc "Extract the embedded bundle blob from a workbook html, or nil if none."
  def extract(html) when is_binary(html) do
    with [_, b64] <- Regex.run(@bundle_re, html),
         {:ok, blob} <- Base.decode64(String.trim(b64)) do
      blob
    else
      _ -> nil
    end
  end

  @doc "True when the html carries an embedded bundle."
  def embedded?(html) when is_binary(html), do: extract(html) != nil

  # Drop any existing wb-bundle block so embed/2 is idempotent (the edit loop:
  # unbundle → edit → re-bundle must not stack stale payloads).
  defp strip_bundle(html), do: Regex.replace(@bundle_re, html, "", global: true) |> String.replace(~r/\n{3,}/, "\n\n")
end
