defmodule Nexus.ArtifactTrust do
  @moduledoc """
  The one seam every image reference passes through before it is deployed or booted — the supply-chain
  trust boundary (red-team wb-skhj / wb-b2ow / wb-um2w).

  ## The problem

  `WB_IMAGE` / `opts[:image]` / a `.work` `runtime-image=` attr / the hardcoded `engine-disk` ref were
  taken verbatim: a malicious deploy block or a poisoned env could point a production deploy at an
  arbitrary attacker image, and every consumer pulled a mutable `:latest` tag with no digest pin.

  ## The primitive (generic, config-driven — THE LINE)

  This is **neutral mechanism**, not our values. The runtime ships permissive defaults; an operator
  (including our own DeployKit, exactly like any customer) declares the policy in their `.work` deploy
  block, read via `Nexus.Config`:

    * `image-registries="ghcr.io/acme/ quay.io/acme/"` — allowed ref **prefixes**. A ref that doesn't
      start with one is refused. Empty (default) ⇒ no restriction (back-compat).
    * `image-pins="ghcr.io/acme/runtime=sha256:abc… …"` — pin a repo to an immutable **content digest**.
      A ref for a pinned repo is rewritten to `repo@<digest>` (the tag is dropped), so a mutable
      `:latest` can't be substituted. Empty (default) ⇒ unpinned.

  `resolve/1` returns the trusted ref to actually use, or an error the caller must fail closed on.
  """

  @doc """
  Resolve an image reference against the trust policy.

  Returns `{:ok, ref}` with the ref to use (digest-pinned if the repo is pinned), or
  `{:error, reason}` — the caller MUST refuse the deploy/boot on an error, never fall back to the raw ref.
  """
  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, atom()}
  def resolve(ref) when is_binary(ref) and ref != "" do
    with :ok <- check_registry(ref) do
      {:ok, apply_pin(ref)}
    end
  end

  def resolve(_), do: {:error, :no_image}

  @doc "Resolve or raise — for call sites that should hard-fail an untrusted ref."
  @spec resolve!(String.t()) :: String.t()
  def resolve!(ref) do
    case resolve(ref) do
      {:ok, r} -> r
      {:error, reason} -> raise ArgumentError, "untrusted image ref #{inspect(ref)}: #{reason}"
    end
  end

  defp check_registry(ref) do
    case Nexus.Config.image_registries() do
      [] -> :ok
      allowed -> if Enum.any?(allowed, &String.starts_with?(ref, &1)), do: :ok, else: {:error, :untrusted_registry}
    end
  end

  # repo (everything before the `:tag` or `@digest`) → if pinned, rewrite to repo@<digest>.
  defp apply_pin(ref) do
    repo = repo_of(ref)

    case Map.get(Nexus.Config.image_pins(), repo) do
      digest when is_binary(digest) -> repo <> "@" <> digest
      _ -> ref
    end
  end

  # Strip a trailing `:tag` or `@digest` to get the bare repo. A `:` in the registry host:port is kept
  # (only the LAST path segment can carry a tag), so split on the final `/` then handle the tag there.
  defp repo_of(ref) do
    case String.split(ref, "@", parts: 2) do
      [base, _digest] -> base
      [base] -> drop_tag(base)
    end
  end

  defp drop_tag(ref) do
    case String.split(ref, "/") do
      [single] -> strip_after_colon(single)
      parts -> (Enum.drop(parts, -1) ++ [strip_after_colon(List.last(parts))]) |> Enum.join("/")
    end
  end

  defp strip_after_colon(seg), do: seg |> String.split(":", parts: 2) |> hd()
end
