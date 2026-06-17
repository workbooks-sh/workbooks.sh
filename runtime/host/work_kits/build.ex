defmodule Workbooks.WorkKits.Build do
  @moduledoc """
  The BUILD half of `Workbooks.WorkKits` — the declarative auto-wrap (`work kit
  build`), inline self-authoring, the session→workspace PROMOTE ladder, and
  third-party manifest provenance (AUTHOR_DID + SIGNATURE).

  A toolkit's CLI is materialized as a sandboxed WASM command (the Dock-gated
  `run-command` path). Native build lanes (cargo/go/zig/script) were REMOVED (wb-9ja);
  this surface honestly reports the lane is gone rather than shelling out.
  """
  alias Workbooks.WorkKits.{Manifest, Registry}

  @manifest "manifest.html"
  @skill_ext ".md"

  # ── Build entry points ─────────────────────────────────────────────────────

  def build_text(id, root), do: build_text(id, nil, root)

  def build_text(id, which, root) do
    case Registry.tk_dir(id, root) do
      nil ->
        "no such toolkit: #{id}"

      dir ->
        entries = Registry.runtime_entries(dir)
        d = Manifest.parse_descriptor(File.read!(Path.join(dir, @manifest)))

        cond do
          # Supply-chain gate: an unsigned/tampered third-party toolkit never builds.
          d.trust == "third-party" and not match?({:ok, _}, manifest_provenance(dir)) ->
            {:error, why} = manifest_provenance(dir)
            "#{id}: REFUSED — third-party toolkit with invalid provenance (#{why}); author must `work kit sign #{id}`"

          entries == [] ->
            do_build(id, d, root)

          which not in [nil, ""] ->
            case Enum.find(entries, fn {n, _} -> n == which end) do
              nil ->
                have = entries |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.join(", ")
                "no such runtime: #{id}/#{which} (have: #{have})"

              {n, f} ->
                do_build("#{id}/#{n}", desc_with_dir(f), root)
            end

          true ->
            entries
            |> Enum.sort()
            |> Enum.map_join("\n", fn {n, f} -> do_build("#{id}/#{n}", desc_with_dir(f), root) end)
        end
    end
  end

  @doc """
  Inline self-authoring: build a command directly from a SOURCE FILE an agent just
  wrote — write → build-in-sandbox → content-address → register, no manifest
  ceremony. Capped by the Instance's Policy profile like any other command.
  """
  def build_inline_text(name, lang, file) do
    if File.regular?(file) do
      case Workbooks.CommandRegistry.build_and_register_inline(name, lang, File.read!(file)) do
        {:ok, path} ->
          "built + registered command `#{name}` (#{lang}) → #{path}\nrun it via the Dock: run-command #{name}"

        {:error, reason} ->
          "build-inline failed for `#{name}` (#{lang}): #{inspect(reason)}"
      end
    else
      "no such source file: #{file}"
    end
  end

  @doc """
  PROMOTE a session command to a durable workspace toolkit (the lifecycle ladder:
  session → workspace → registry). Persists the SOURCE (rebuildable), not just the
  compiled bytes. Trust stays first-party.
  """
  def promote_text(name, lang, src_file, opts \\ []) do
    root = opts[:root] || Registry.default_root()
    tagline = opts[:tagline] || "Promoted session command."

    cond do
      name in Workbooks.CommandRegistry.reserved_names() ->
        "cannot promote: #{inspect(name)} is a reserved built-in command name"

      not Regex.match?(~r/^[A-Za-z0-9_.-]+$/, name) ->
        "cannot promote: invalid toolkit/command name #{inspect(name)}"

      lang not in ~w(rust c zig js ts go) ->
        "cannot promote: unsupported language #{inspect(lang)}"

      not File.regular?(src_file) ->
        "cannot promote: no such source file #{inspect(src_file)}"

      true ->
        {build_src, entry_rel, extra} = lang_layout(lang, name)
        dir = Path.join(root, name)
        source = File.read!(src_file)

        File.mkdir_p!(Path.dirname(Path.join(dir, entry_rel)))
        File.write!(Path.join(dir, entry_rel), source)

        for {rel, bytes} <- extra do
          File.mkdir_p!(Path.dirname(Path.join(dir, rel)))
          File.write!(Path.join(dir, rel), bytes)
        end

        File.mkdir_p!(Path.join(dir, "skills"))
        File.write!(Path.join(dir, "skills/overview#{@skill_ext}"), promote_skill(name))
        File.write!(Path.join(dir, @manifest), promote_manifest(name, lang, build_src, tagline))

        "promoted session command → workspace toolkit `#{name}` at #{dir}\n" <>
          "  build it: work kit build #{name}\n" <>
          "  then it packs into a workbook (Library.store) and installs elsewhere (Library.install)"
    end
  end

  # Per-language source layout build_dir/2 expects, relative to the toolkit dir.
  defp lang_layout("rust", name),
    do: {".", "src/main.rs", %{"Cargo.toml" => ~s|[package]\nname = "#{name}"\nversion = "0.1.0"\nedition = "2021"\n|}}

  defp lang_layout("js", _name), do: {"src", "src/index.js", %{}}
  defp lang_layout("ts", _name), do: {"src", "src/index.ts", %{}}
  defp lang_layout("zig", _name), do: {"src", "src/main.zig", %{}}
  defp lang_layout("go", _name), do: {"src", "src/main.go", %{}}
  defp lang_layout("c", _name), do: {"src", "src/main.c", %{}}

  defp promote_manifest(name, lang, build_src, tagline) do
    """
    <work-ref rel="kit"
      name="#{name}"
      prefix="#{name}"
      cli="#{name}"
      version="0.1.0"
      status="experimental"
      tagline="#{tagline}"
      exec="command"
      trust="first-party"
      build-lang="#{lang}"
      build-src="path:#{build_src}"
      arg-mode="argv"/>
    <work-doc title="#{name} toolkit">
      Promoted from a session command (wb-rhs.6). Source-owned + rebuildable.

      | need   | skill    |
      |--------|----------|
      | use it | overview |
    </work-doc>
    """
  end

  defp promote_skill(name) do
    """
    # #{name} — overview

    ## When to use this
    A command promoted from a session. NOT for anything else yet — extend the
    skill as the toolkit grows.

    ## Workflow
    Run it through the Dock: `run-command #{name}` (argv + stdin → stdout).

    ## Verification checklist
    - [ ] `work kit build #{name}` registers the command
    - [ ] `run-command #{name}` produces expected output
    """
  end

  defp desc_with_dir(file),
    do: Manifest.parse_descriptor(File.read!(file)) |> Map.put(:src_dir, Path.dirname(file))

  # ── do_build dispatch ──────────────────────────────────────────────────────

  defp do_build(id, %{cli_bin: nil}, _root),
    do: "cannot build #{id}: no CLI_BIN declared (nothing to register a command under)"

  # A toolkit's CLI_BIN is attacker-controlled DATA. Refuse to register a command
  # under a RESERVED built-in name when this descriptor would register one.
  defp do_build(id, %{cli_bin: bin, exec: exec, build_src: {kind, _}} = d, root)
       when is_binary(bin) and exec in ["command", nil] and kind in [:crate, :path, :wasm, :archive, :gobuild, :script, :zigbuild] do
    if bin in Workbooks.CommandRegistry.reserved_names() do
      "cannot build #{id}: CLI_BIN #{inspect(bin)} is a reserved built-in command name (refusing to shadow it)"
    else
      Workbooks.CommandRegistry.set_trust(bin, d[:trust] || "first-party")
      do_build_clause(id, d, root)
    end
  end

  defp do_build(id, d, root), do: do_build_clause(id, d, root)

  defp do_build_clause(id, %{exec: exec}, _root) when exec in ["task", "federation"],
    do: "#{id}: #+EXEC: #{exec} — no command to build (task/federation toolkits ship no CLI binary)"

  defp do_build_clause(id, %{exec: "posix", cli_bin: bin}, _root) do
    case System.find_executable(bin) do
      nil -> "#{id}: #+EXEC: posix — native binary #{inspect(bin)} not found on PATH (install it; nothing to build)"
      path -> "#{id}: #+EXEC: posix — native binary #{bin} present at #{path} (no WASM build needed)"
    end
  end

  defp do_build_clause(id, %{exec: exec, build_src: {:crate, crate}}, _root)
       when exec in ["command", nil],
       do: "#{id}: native cargo build of crate #{crate} removed (wb-9ja) — fetching+building an upstream binary crate natively is banned; vendor the source and use path:<dir> (in-sandbox rust lane)"

  defp do_build_clause(id, %{exec: exec, build_src: {:path, dir}, build_lang: lang, cli_bin: bin, arg_mode: mode}, root)
       when exec in ["command", nil] do
    lang = lang || "rust"
    abs = if Path.type(dir) == :absolute, do: dir, else: Path.join(Registry.tk_dir(id, root) || ".", dir)

    case Workbooks.PackageManager.build_dir(abs, lang) do
      {:ok, wasm, _} ->
        case Workbooks.CommandRegistry.register_artifact(bin, wasm, mode) do
          {:ok, addressed} ->
            "#{id}: built #{lang} dir #{abs} → #{addressed}; registered command #{inspect(bin)} (mode #{mode})"

          {:error, reason} ->
            "#{id}: built #{lang} dir #{abs} but FAILED to content-address:\n" <> error_text(reason)
        end

      {:error, reason} ->
        "#{id}: build FAILED for path #{abs} (#{lang}):\n" <> error_text(reason)
    end
  end

  # #+EXEC: kernel — a bytes→bytes reactor, NOT a stdio command.
  defp do_build_clause(id, %{exec: "kernel", build_src: {:path, dir}, build_lang: lang, cli_bin: bin}, root)
       when lang in ["c", nil] do
    abs = if Path.type(dir) == :absolute, do: dir, else: Path.join(Registry.tk_dir(id, root) || ".", dir)

    case Path.wildcard(Path.join(abs, "**/*.c")) do
      [] ->
        "#{id}: kernel build — no .c source in #{abs}"

      [entry | _] ->
        case Workbooks.Compilers.c_compile_to_kernel(entry) do
          {:ok, wasm, _} ->
            case Workbooks.KernelRegistry.register(bin, wasm) do
              {:ok, addressed} -> "#{id}: built C kernel #{entry} → #{addressed}; registered kernel #{inspect(bin)}"
              {:error, reason} -> "#{id}: kernel built but register FAILED:\n" <> error_text(reason)
            end

          {:error, reason} ->
            "#{id}: kernel build FAILED for #{entry}:\n" <> error_text(reason)
        end
    end
  end

  defp do_build_clause(id, %{exec: "kernel", build_lang: lang}, _root),
    do: "#{id}: #+EXEC: kernel — only #+BUILD_LANG: c is supported today (got #{inspect(lang)}); needs #+BUILD_SRC: path:<dir> with a .c source"

  # wasm:<url> — a PREBUILT runtime/compiler: fetch, sha-verify, content-address, register.
  defp do_build_clause(id, %{exec: exec, build_src: {:wasm, url}, cli_bin: bin, arg_mode: mode, sha256: sha}, _root)
       when exec in ["command", nil] do
    case Workbooks.CommandRegistry.fetch_and_register_wasm(bin, url, sha, mode) do
      {:ok, addressed, hash} ->
        pin = if sha in [nil, ""], do: "  (UNPINNED — add `#+SHA256: #{hash}` to the manifest)", else: ""
        "#{id}: fetched prebuilt #{url} → #{addressed}; registered command #{inspect(bin)} (mode #{mode})#{pin}"

      {:error, reason} ->
        "#{id}: fetch FAILED for #{url}:\n" <> error_text(reason)
    end
  end

  # archive:<url> — a PREBUILT runtime that ships as a tar.gz: fetch + sha-verify + unpack + register.
  defp do_build_clause(id, %{exec: exec, build_src: {:archive, url}, cli_bin: bin, arg_mode: mode, sha256: sha, wasm_path: wp, preopen: pre}, _root)
       when exec in ["command", nil] do
    case Workbooks.CommandRegistry.fetch_and_register_archive(bin, url, sha, wp, pre, mode) do
      {:ok, addressed, hash} ->
        pin = if sha in [nil, ""], do: "  (UNPINNED — add `#+SHA256: #{hash}` to the manifest)", else: ""
        "#{id}: fetched + unpacked #{url} → #{addressed}; registered command #{inspect(bin)} (mode #{mode}, preopen #{pre || ".::/"})#{pin}"

      {:error, reason} ->
        "#{id}: fetch/unpack FAILED for #{url}:\n" <> error_text(reason)
    end
  end

  # gobuild / zigbuild / script — NATIVE build lanes REMOVED (wb-9ja).
  defp do_build_clause(id, %{exec: exec, build_src: {:gobuild, pkg}}, _root)
       when exec in ["command", nil],
       do: "#{id}: native go build of #{pkg} removed (wb-9ja) — no in-sandbox lane for fetching+building an upstream Go package; use a prebuilt wasm:/archive: source or the in-sandbox go SOURCE lane"

  defp do_build_clause(id, %{exec: exec, build_src: {:zigbuild, rel}}, _root)
       when exec in ["command", nil],
       do: "#{id}: native zig build of #{rel} removed (wb-9ja) — compile Zig SOURCE in-sandbox via the zig lane instead"

  defp do_build_clause(id, %{exec: exec, build_src: {:script, rel}}, _root)
       when exec in ["command", nil],
       do: "#{id}: native build script #{rel} removed (wb-9ja) — native bash build scripts are banned; fetch a prebuilt wasm via wasm:/archive: #+BUILD_SRC"

  defp do_build_clause(id, %{build_src: nil}, _root),
    do: "#{id}: no #+BUILD_SRC declared — nothing to build (declare crate:<name> | path:<dir> | wasm:<url> | archive:<url>)"

  defp do_build_clause(id, %{build_src: {:git, url}}, _root),
    do: "#{id}: #+BUILD_SRC git+#{url} not yet supported by `work kit build` (use crate: or path:)"

  defp do_build_clause(id, %{build_src: {:unknown, spec}}, _root),
    do: "#{id}: unrecognized #+BUILD_SRC #{inspect(spec)} (expected crate:<name> | git+<url> | path:<dir>)"

  defp error_text(reason) when is_binary(reason), do: String.slice(reason, -2000, 2000)
  defp error_text(reason), do: inspect(reason)

  # ── Third-party trust: manifest provenance (AUTHOR_DID + SIGNATURE) ─────────

  @doc "Sign a toolkit's manifest as `tenant`: writes #+AUTHOR_DID + #+SIGNATURE."
  def sign_text(id, tenant, root) do
    case Registry.tk_dir(id, root) do
      nil ->
        "no such toolkit: #{id}"

      dir ->
        path = Path.join(dir, @manifest)
        did = Workbooks.Git.did(tenant)

        body =
          File.read!(path)
          |> Manifest.strip_manifest_lines(["SIGNATURE", "AUTHOR_DID"])
          |> Kernel.<>("\n#+AUTHOR_DID: #{did}")
          |> String.trim()

        sig = Workbooks.Git.sign(tenant, body) |> Base.encode64()
        File.write!(path, body <> "\n#+SIGNATURE: #{sig}\n")
        "signed #{id} as #{did}"
    end
  end

  @doc "Verify a manifest's provenance: {:ok, did} | {:error, reason}."
  def manifest_provenance(dir) do
    body = File.read!(Path.join(dir, @manifest))
    d = Manifest.parse_descriptor(body)

    cond do
      is_nil(d.author_did) -> {:error, :no_author_did}
      is_nil(d.signature) -> {:error, :no_signature}
      true ->
        canonical = body |> Manifest.strip_manifest_lines(["SIGNATURE"]) |> String.trim()

        case Base.decode64(d.signature) do
          {:ok, sig} ->
            if Workbooks.Git.verify_sig(d.author_did, canonical, sig),
              do: {:ok, d.author_did},
              else: {:error, :bad_signature}

          :error ->
            {:error, :bad_signature_encoding}
        end
    end
  end

  @doc "Structural verify check for a third-party toolkit's provenance ([] for first-party)."
  def trust_checks(dir, %{trust: "third-party"}) do
    case manifest_provenance(dir) do
      {:ok, did} -> [{true, "third-party signature valid (#{did})"}]
      {:error, why} -> [{false, "third-party provenance: #{why} (sign with `work kit sign <id>`)"}]
    end
  end

  def trust_checks(_dir, _first_party), do: []
end
