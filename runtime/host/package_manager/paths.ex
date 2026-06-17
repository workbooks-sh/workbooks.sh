defmodule Workbooks.PackageManager.Paths do
  @moduledoc """
  Shared cache layer for the build pipeline: the on-disk locations (cache dir,
  content-addressed commands store, trusted-tools dir) plus the content-address
  primitives (`cache_key/1`, `content_address/1`). One home, so the Build / Run /
  Compose lanes that split out of PackageManager never drift on where artifacts
  live or how they're hashed.
  """

  @root Path.expand(Path.join([__DIR__, "..", "..", "build"]))

  @doc "Content-addressed build cache (build/cache/)."
  def cache, do: Path.join(@root, "cache")

  @doc "Content-addressed registered-command store (build/commands/)."
  def commands, do: Path.join(@root, "commands")

  @doc "Trusted prebuilt tools dir (build/tools/) — adapter, wac, wasm-tools.wasm."
  def tools, do: Path.join(@root, "tools")

  @doc "Content-addressed cache key for a build input set."
  def cache_key(parts),
    do: :crypto.hash(:sha256, Enum.join(parts, "\0")) |> Base.encode16(case: :lower)

  @doc """
  Content-address a built command artifact: hash its BYTES (sha256), copy it to
  `build/commands/<sha>.wasm`, and return that stable path. Identical source ⇒
  identical wasm ⇒ identical hash ⇒ same path — so rebuilds are idempotent (the
  copy is skipped when the addressed file already exists). This is the path a
  command is REGISTERED under, decoupling the registry from transient cache/temp
  build outputs. Returns {:ok, addressed_path, sha} | {:error, reason}.
  """
  def content_address(wasm_path) do
    case File.read(wasm_path) do
      {:ok, bytes} ->
        sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
        File.mkdir_p!(commands())
        addressed = Path.join(commands(), "#{sha}.wasm")
        unless File.exists?(addressed), do: File.write!(addressed, bytes)
        {:ok, addressed, sha}

      {:error, reason} ->
        {:error, {:read_artifact, wasm_path, reason}}
    end
  end
end
