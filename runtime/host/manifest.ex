defmodule Workbooks.Manifest do
  @moduledoc """
  Sign a published Workbook artifact (HTML) with the tenant's did:key — the
  ARTIFACT rail of sharing (provenance that travels with the bytes after they
  leave the platform). Pure Elixir on the same Ed25519 key the ledger uses
  (`Workbooks.Git`): no C2PA/X.509 stack, no Rust signer binary, no external
  tool.

  The archive proved the scheme across three impls (Rust signer + Elixir + a
  WebCrypto verifier) — an embedded Ed25519-over-canonical-JSON manifest, NOT a
  full COSE/X.509 C2PA claim. We adopt the scheme, drop the machinery: the
  did:key is self-certifying (the verifier decodes the pubkey straight from the
  DID), so the heavy cert chain the C2PA spike planned isn't needed. That spike's
  X.509 path is SUPERSEDED by this — see docs/C2PA-DIDKEY-SPIKE.org.

  A signed `.html` carries `<script type="application/workbooks-c2pa+json">` with
  the manifest + signature. `verify/1` checks two things (either fail ⇒ invalid):

    1. SIGNATURE — Ed25519 over `canonical(manifest)` validates under the key the
       `issuer_did` encodes (binds artifact ⇄ identity; collapses the archive's
       sig + did-match checks since did:key IS the pubkey).
    2. ASSET INTEGRITY — `sha256(html_without_manifest)` == `asset_sha256` (the
       bytes weren't altered after signing).

  Canonical JSON = recursively key-sorted, compact, UTF-8 — the one cross-impl
  contract a browser/Rust verifier must match.
  """
  alias Workbooks.Git

  @tag_open ~s(<script type="application/workbooks-c2pa+json" id="wb-c2pa-manifest">)
  @tag_close "</script>"
  @version "v1"
  @generator "workbooks-runtime/0.1"

  @doc """
  Sign `html` as `tenant`, embedding a signed manifest. `assertions` is a list of
  plain maps (e.g. `%{"type" => "c2pa.action.published", "actor" => did}`).
  Idempotent — re-signing strips any prior manifest first. Returns the signed HTML.
  """
  def sign(html, tenant, assertions \\ [], opts \\ []) when is_binary(html) do
    stripped = strip(html)

    manifest = %{
      "version" => @version,
      "issuer_did" => Git.did(tenant),
      "claim_generator" => Keyword.get(opts, :claim_generator, @generator),
      "issued_at" => Keyword.get_lazy(opts, :issued_at, &iso_now/0),
      "asset_sha256" => sha256_hex(stripped),
      "assertions" => assertions
    }

    sig = Git.sign(tenant, canonical(manifest)) |> Base.encode64()
    block = @tag_open <> Jason.encode!(Map.put(manifest, "signature", sig)) <> @tag_close
    inject(stripped, block)
  end

  @doc "Verify a signed artifact: signature + asset integrity. Pure-read, no key needed for the asset half."
  def verify(html) when is_binary(html) do
    case extract(html) do
      nil -> %{error: "no manifest"}
      full ->
        {sig, manifest} = Map.pop(full, "signature")
        sig_ok = sig && Git.verify_sig(manifest["issuer_did"], canonical(manifest), Base.decode64!(sig))
        hash_ok = manifest["asset_sha256"] == sha256_hex(strip(html))

        %{signature: !!sig_ok, asset_integrity: hash_ok, valid: !!sig_ok and hash_ok,
          issuer_did: manifest["issuer_did"], issued_at: manifest["issued_at"],
          assertions: manifest["assertions"] || []}
    end
  rescue
    e -> %{error: Exception.message(e)}
  end

  # ── canonical JSON: the one cross-impl byte contract ─────────────────────────
  defp canonical(m) when is_map(m) do
    inner = m |> Enum.sort_by(fn {k, _} -> to_string(k) end)
              |> Enum.map_join(",", fn {k, v} -> Jason.encode!(to_string(k)) <> ":" <> canonical(v) end)
    "{" <> inner <> "}"
  end

  defp canonical(l) when is_list(l), do: "[" <> Enum.map_join(l, ",", &canonical/1) <> "]"
  defp canonical(other), do: Jason.encode!(other)

  # ── html embedding ───────────────────────────────────────────────────────────
  defp strip(html), do: String.replace(html, ~r/#{Regex.escape(@tag_open)}.*?#{Regex.escape(@tag_close)}/s, "")

  defp extract(html) do
    case Regex.run(~r/#{Regex.escape(@tag_open)}(.*?)#{Regex.escape(@tag_close)}/s, html) do
      [_, json] -> Jason.decode!(json)
      _ -> nil
    end
  end

  defp inject(html, block) do
    if String.contains?(html, "</body>"),
      do: String.replace(html, "</body>", block <> "</body>", global: false),
      else: html <> block
  end

  defp sha256_hex(b), do: :crypto.hash(:sha256, b) |> Base.encode16(case: :lower)
  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
