defmodule Workbooks.Did do
  @moduledoc """
  did:web — the self-host identity rail (Phase 2e). The same Ed25519 key behind
  the tenant's `did:key` (`Workbooks.Git`), republished as a `did:web` document
  resolvable over plain HTTPS. "Self-host for now": no Radicle, no PLC, no
  registry — a standard DID resolver fetches `https://<host>/.well-known/did.json`
  and gets the engine's verification key.

  did:key and did:web wrap the SAME public key, so a signature made by the ledger
  / artifact signer verifies under EITHER DID — did:web just makes the identity
  resolvable by HTTPS-aware verifiers (and is the bridge target a did:plc/ATproto
  record can reference later).
  """
  alias Workbooks.Git

  @doc """
  The DID document for a tenant served at `host`. `host` is the bare authority
  (e.g. `bn-engine-agents.fly.dev`). The verification method's multibase key is
  lifted straight from the tenant's did:key (same bytes, same `z…` encoding).
  """
  def web_document(host, tenant \\ "dev") do
    multibase = Git.did(tenant) |> String.replace_prefix("did:key:", "")
    id = "did:web:#{host}"
    vm = "#{id}#owner"

    %{
      "@context" => [
        "https://www.w3.org/ns/did/v1",
        "https://w3id.org/security/suites/ed25519-2020/v1"
      ],
      "id" => id,
      "verificationMethod" => [
        %{
          "id" => vm,
          "type" => "Ed25519VerificationKey2020",
          "controller" => id,
          "publicKeyMultibase" => multibase
        }
      ],
      "authentication" => [vm],
      "assertionMethod" => [vm],
      # Cross-link the equivalent did:key so a verifier holding a did:key
      # signature can confirm it's the same subject (and vice-versa).
      "alsoKnownAs" => [Git.did(tenant)],
      # Where this identity serves its workbooks — the resolution target for a
      # DID-referenced member (`resolve/1`). Standard DID `service` entry.
      "service" => [%{
        "id" => "#{id}#workbooks",
        "type" => "WorkbookHost",
        "serviceEndpoint" => "https://#{host}/docs"
      }]
    }
  end

  @doc """
  The did.json URL for a `did:web` (the DID method's path rules):
  `did:web:host` → `https://host/.well-known/did.json`;
  `did:web:host:a:b` → `https://host/a/b/did.json`. (`%3A` in the host = a port.)
  """
  def doc_url("did:web:" <> rest) do
    [host | segs] = rest |> String.split(":") |> Enum.map(&URI.decode/1)

    case segs do
      [] -> "https://#{host}/.well-known/did.json"
      _ -> "https://#{host}/#{Enum.join(segs, "/")}/did.json"
    end
  end

  @doc """
  Resolve a DID-referenced member to its workbook bytes. did:web is concrete:
  fetch the DID document, find its `WorkbookHost` service, fetch the workbook.
  did:key / Radicle have no inherent location, so they need a registry / the
  `rad`-network resolver — documented extension points, returned as honest errors.
  Returns {:ok, bytes} | {:error, reason}.
  """
  def resolve("did:web:" <> _ = did) do
    with {:ok, body} <- http_get(doc_url(did)),
         {:ok, doc} <- Jason.decode(body),
         url when is_binary(url) <- workbook_endpoint(doc) do
      http_get(url)
    else
      nil -> {:error, "no WorkbookHost service in #{did}"}
      {:error, e} -> {:error, e}
    end
  end

  def resolve("did:key:" <> _ = did), do: {:error, "did:key has no location — needs a registry/ledger anchor (extension): #{did}"}
  def resolve("did:" <> _ = did), do: {:error, "unsupported DID method for resolution: #{did}"}
  def resolve(other), do: {:error, "not a DID: #{inspect(other)}"}

  defp workbook_endpoint(%{"service" => svcs}) when is_list(svcs) do
    Enum.find_value(svcs, fn s ->
      if is_binary(s["type"]) and String.contains?(s["type"], "Workbook"), do: s["serviceEndpoint"], else: nil
    end)
  end

  defp workbook_endpoint(_), do: nil

  defp http_get(url) do
    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: 20_000, autoredirect: true], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> {:ok, body}
      {:ok, {{_, status, _}, _, _}} -> {:error, "HTTP #{status} from #{url}"}
      {:error, e} -> {:error, inspect(e)}
    end
  end
end
