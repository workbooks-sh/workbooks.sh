defmodule Nexus.Lang do
  @moduledoc """
  A **WebAssembly compiler language** — one pluggable source language nexus can compile to wasm. This
  is the explicit interface (and `Nexus.Langs` the registry) for the language backends that were
  otherwise loose modules under `Nexus.Compilers.*`. Each `Nexus.Lang` declares its `id` (the
  `node.lang` string), the output `shapes` it supports, and compiles source to wasm.

  Two output shapes (don't confuse a LANGUAGE with a TOOLKIT — a toolkit is a wrapped CLI an *agent*
  runs; a language is how *source* becomes wasm):

    * `:command` — a `wasm32-wasi` CLI module (`main()`, argv/stdin → stdout). What a **toolkit** is
      built from. Uniform across languages, so it lives here.
    * `:component` — a WIT-export module, for `resource`/render units. This is unit-and-WIT-specific,
      so its orchestration stays in `Nexus.Compile`; a language just *declares* whether it supports it.

  **To add a language:** implement this behaviour and `Nexus.Langs.register/1`. That's the whole
  extension surface — a new wasm compiler language drops in without touching the orchestrator.
  """

  @type shape :: :command | :component

  @doc "The language id — matches a unit's `lang` (e.g. \"rust\")."
  @callback id() :: String.t()

  @doc "A one-line human description (shown when listing languages)."
  @callback summary() :: String.t()

  @doc "The output shapes this language supports."
  @callback shapes() :: [shape]

  @doc "Compile a source file to wasm in `shape`. `{:ok, wasm_path} | {:error, reason}`."
  @callback compile(source_path :: String.t(), shape, opts :: keyword) :: {:ok, String.t()} | {:error, term}
end

defmodule Nexus.Langs do
  @moduledoc """
  The registry of `Nexus.Lang` backends — the explicit, single home for "which WebAssembly compiler
  languages does nexus have, and how do I add one." Built-ins: C, Rust, Zig. Register more with
  `register/1`.
  """

  @builtin [Nexus.Lang.C, Nexus.Lang.Rust, Nexus.Lang.Zig]
  @reg {:nexus_langs, :registered}

  @doc "All language backends (built-in + registered)."
  def all, do: @builtin ++ :persistent_term.get(@reg, [])

  @doc "Register a custom `Nexus.Lang` backend (extension point)."
  def register(mod) do
    :persistent_term.put(@reg, Enum.uniq([mod | :persistent_term.get(@reg, [])]))
    :ok
  end

  @doc "Drop registered (non-builtin) languages."
  def clear_registered, do: :persistent_term.put(@reg, [])

  @doc "The language backend for an id (e.g. \"rust\"), or nil."
  def get(id), do: Enum.find(all(), &(&1.id() == id))

  @doc "All known language ids."
  def ids, do: Enum.map(all(), & &1.id())

  @doc "Whether language `id` supports output `shape`."
  def supports?(id, shape) do
    case get(id) do
      nil -> false
      lang -> shape in lang.shapes()
    end
  end

  @doc "Compile `source_path` in `shape` using language `id`. `{:error, {:unknown_lang, id}}` if absent."
  def compile(id, source_path, shape, opts \\ []) do
    case get(id) do
      nil -> {:error, {:unknown_lang, id}}
      lang -> if shape in lang.shapes(), do: lang.compile(source_path, shape, opts), else: {:error, {:unsupported_shape, id, shape}}
    end
  end

  @doc "A one-line catalog of languages + the shapes each supports (for docs / introspection)."
  def catalog do
    Enum.map_join(all(), "\n", fn l -> "  #{l.id()} (#{Enum.join(l.shapes(), ", ")}) — #{l.summary()}" end)
  end
end
