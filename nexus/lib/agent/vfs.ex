defmodule Nexus.Agent.Vfs do
  @moduledoc """
  The agent's virtual filesystem — a real workspace directory mounted into wasmtime as a preopened
  dir (`--dir <host>::/work`). Bash commands run against `/work`; that's the agent's whole world.
  No host filesystem reach beyond this dir (wasmtime grants only the preopen), so the agent is
  sandboxed by construction.

  A Vfs is just a path + helpers to create/seed/read/destroy it. One per agent run, cleaned up after.
  """

  defstruct [:dir]
  @type t :: %__MODULE__{dir: String.t()}

  @guest "/work"

  @doc "Create a fresh workspace dir for an agent run."
  def new do
    dir = Path.join(System.tmp_dir!(), "nexus_vfs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    %__MODULE__{dir: dir}
  end

  @doc "The guest mount point bash sees (`/work`)."
  def guest_root, do: @guest

  @doc "The wasmtime `--dir` mapping for this vfs (`<host>::/work`)."
  def mount(%__MODULE__{dir: dir}), do: "#{dir}::#{@guest}"

  @doc "Write a file into the workspace (path relative to /work)."
  def put(%__MODULE__{dir: dir}, rel, contents) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    :ok
  end

  @doc "Read a file from the workspace (nil if absent)."
  def get(%__MODULE__{dir: dir}, rel) do
    case File.read(Path.join(dir, rel)) do
      {:ok, c} -> c
      _ -> nil
    end
  end

  @doc "List the workspace files (relative paths)."
  def ls(%__MODULE__{dir: dir}) do
    Path.wildcard(Path.join(dir, "**/*"))
    |> Enum.reject(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, dir))
  end

  @doc "Destroy the workspace."
  def destroy(%__MODULE__{dir: dir}), do: File.rm_rf(dir)
end
