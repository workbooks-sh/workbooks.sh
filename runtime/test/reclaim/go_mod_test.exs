defmodule Workbooks.Reclaim.GoModTest do
  @moduledoc """
  RECLAIM DURABILITY TEST — `go mod`: fetch a third-party Go module and RUN a program that imports it,
  entirely in the WASM sandbox.

  resolved.json claim: the full go-mod loop works in-sandbox — resolve+fetch a module from
  proxy.golang.org over brokered HTTP, then run a Go program that IMPORTS the fetched third-party module
  in the wasm sandbox via yaegi with a GOPATH preopen. The recipe's one runner change:
  interp.Options{GoPath: env("WBGOPATH")}, rebuild to wasip1, and add the staged GOPATH dir as a `/gp`
  preopen with WBGOPATH=/gp.

  SELF-CONTAINED — every recipe step lives here, touching NO shared host file:
    * RESOLVE: GET proxy.golang.org/<module>/@latest for the version (host-side Workbooks.CappedHttp.get).
    * FETCH:   GET /@v/<ver>.zip; unzip into a GOPATH/src/<module-path> layout (zip members are
               <module>@<ver>/...).
    * BUILD:   compile this test's OWN runner.go (the GoPath variant, a committed fixture) to wasm32-wasip1
               with the native Go toolchain in a throwaway module dir (yaegi dep resolved from GOMODCACHE).
               This is the trusted one-time provisioning the shipped lane already does — it never compiles
               user code.
    * RUN:     wasmtime the runner with the staged GOPATH preopened at /gp + WBGOPATH=/gp, evaluating a Go
               program that imports github.com/google/uuid and computes a real SHA1 UUID.

  HONESTY: this proves a ZERO-DEP, generics-free, pure-Go module (github.com/google/uuid) interprets under
  yaegi from a fetched GOPATH. yaegi is an interpreter — modules using cgo, heavy generics, unsafe, or
  build-tag tricks will NOT all interpret. The claim is "third-party import resolution from a fetched
  GOPATH works", which this empirically establishes; it is NOT "all of crates-equivalent Go works".
  """
  use ExUnit.Case, async: false

  @moduletag :build
  @moduletag :netdeps
  @moduletag timeout: 600_000

  @runner_fixture Path.join([__DIR__, "fixtures", "go_mod", "runner.go"])
  @yaegi_root Path.expand(Path.join([__DIR__, "..", "..", "compilers", "go", "yaegi-root"]))

  @module "github.com/google/uuid"

  # the untrusted Go program the sandbox interprets — imports the FETCHED third-party module
  @prog ~S"""
  package main
  import ("fmt"; "github.com/google/uuid")
  func main(){
    u := uuid.NewSHA1(uuid.NameSpaceURL, []byte("workbooks"))
    fmt.Println("UUID", u.String())
  }
  """

  setup_all do
    # need the native Go toolchain to build the trusted runner, and wasmtime to run it
    go = System.find_executable("go")
    wasmtime = System.find_executable("wasmtime")

    cond do
      is_nil(go) -> {:ok, skip: "no native go toolchain"}
      is_nil(wasmtime) -> {:ok, skip: "no wasmtime"}
      true -> {:ok, skip: nil}
    end
  end

  defp tmp(name), do: Path.join(System.tmp_dir!(), "reclaim-gomod-#{:erlang.unique_integer([:positive])}-#{name}")

  # RESOLVE — proxy.golang.org/<mod>/@latest -> version
  defp resolve_version(mod) do
    url = ~c"https://proxy.golang.org/#{mod}/@latest"

    case Workbooks.CappedHttp.get(url, [], [{:timeout, 60_000}], 1_000_000, 60_000) do
      {:ok, _h, body} ->
        case Regex.run(~r/"Version":"([^"]+)"/, body) do
          [_, ver] -> {:ok, ver}
          _ -> {:error, {:no_version, body}}
        end

      e ->
        e
    end
  end

  # FETCH — /@v/<ver>.zip -> unzip into GOPATH/src/<mod>
  defp fetch_into_gopath(mod, ver, gopath) do
    url = ~c"https://proxy.golang.org/#{mod}/@v/#{ver}.zip"

    case Workbooks.CappedHttp.get(url, [], [{:timeout, 120_000}], 50_000_000, 120_000) do
      {:ok, _h, zip} ->
        zpath = tmp("mod.zip")
        File.write!(zpath, zip)
        unz = tmp("unz")
        File.mkdir_p!(unz)
        # Go module zips use flags erlang's :zip rejects (badarg); use the host unzip CLI.
        {_, 0} = System.cmd("unzip", ["-q", "-o", zpath, "-d", unz], stderr_to_stdout: true)
        # members are <mod>@<ver>/... -> copy into gopath/src/<mod>/
        src = Path.join(unz, "#{mod}@#{ver}")
        dst = Path.join([gopath, "src", mod])
        File.mkdir_p!(dst)
        File.cp_r!(src, dst)
        :ok

      e ->
        e
    end
  end

  # BUILD — compile the GoPath-variant runner fixture to wasm32-wasip1 in a throwaway module dir.
  defp build_runner_wasm do
    dir = tmp("runner")
    File.mkdir_p!(dir)
    File.cp!(@runner_fixture, Path.join(dir, "main.go"))
    # reuse the already-resolved yaegi module graph (offline build from GOMODCACHE)
    File.cp!(Path.join(@yaegi_root, "go.mod"), Path.join(dir, "go.mod"))
    File.cp!(Path.join(@yaegi_root, "go.sum"), Path.join(dir, "go.sum"))
    out = Path.join(dir, "runner.wasm")

    env = [
      {"GOOS", "wasip1"},
      {"GOARCH", "wasm"},
      {"GOFLAGS", "-mod=mod"}
    ]

    case System.cmd("go", ["build", "-o", out, "."], cd: dir, env: env, stderr_to_stdout: true) do
      {_, 0} -> {:ok, out}
      {log, code} -> {:error, {:go_build_failed, code, log}}
    end
  end

  test "fetch a third-party Go module from proxy.golang.org + import it in-sandbox via yaegi GOPATH" do
    {:ok, ver} = resolve_version(@module)
    assert ver =~ ~r/^v\d/, "bad version #{inspect(ver)}"

    gopath = tmp("gp")
    File.mkdir_p!(Path.join(gopath, "src"))
    assert :ok = fetch_into_gopath(@module, ver, gopath)

    # the fetched module's real source landed on GOPATH
    assert File.exists?(Path.join([gopath, "src", @module, "uuid.go"])),
           "fetched module source not staged into GOPATH"

    {:ok, runner_wasm} = build_runner_wasm()
    assert File.regular?(runner_wasm)

    work = tmp("work")
    File.mkdir_p!(work)
    File.write!(Path.join(work, "prog.go"), @prog)

    # RUN — wasmtime the trusted runner with the GOPATH preopened at /gp + WBGOPATH=/gp
    args =
      [
        "run",
        "--env",
        "WBGOPATH=/gp",
        "--dir",
        "#{work}::/work",
        "--dir",
        "#{gopath}::/gp",
        runner_wasm,
        "/work/prog.go"
      ]

    {out, status} = System.cmd("wasmtime", args, stderr_to_stdout: true)

    assert status == 0, "wasmtime exited #{status}:\n#{out}"
    # a real UUID string (8-4-4-4-12 hex) computed BY the fetched third-party module inside the sandbox
    assert out =~ ~r/UUID [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/,
           "no UUID from the imported module — third-party import didn't resolve in-sandbox:\n#{out}"
  end
end
