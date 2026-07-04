defmodule Nexus.Subprocess do
  @moduledoc """
  Shared helper for shelling out to an UNTRUSTED subprocess with a secret-free environment.

  Every subprocess we spawn for guest-adjacent work — the wasm command/compiler lanes, mrustc proc-macro
  servers, the Wasmer shell, the Blitz browser render — must not carry injected secrets
  (`OPENROUTER_API_KEY`, `WB_*`, tokens) into a process a guest can reach via `getenv`. `scrubbed_env/0`
  UNSETs every inherited var (`{k, nil}`) except a tiny operational allowlist; guest-visible env is passed
  separately as explicit flags by each lane.

  Lives here (not in `Nexus.Sandbox`) so it outlives the wasmtime-CLI runner: the wasmtime→TinyLasers
  cutover (wb-4z3fv) deletes `Nexus.Sandbox`, but these other subprocess lanes keep needing a scrubbed env.
  """

  # Only genuinely operational vars survive; everything else (secrets, WB_*, tokens) is unset.
  @env_allow ~w(PATH HOME TMPDIR LANG LC_ALL LC_CTYPE USER SHELL TERM)

  @doc "A `System.cmd` `:env` list that UNSETS every inherited var outside the operational allowlist."
  def scrubbed_env do
    for {k, _v} <- System.get_env(), k not in @env_allow, do: {k, nil}
  end
end
