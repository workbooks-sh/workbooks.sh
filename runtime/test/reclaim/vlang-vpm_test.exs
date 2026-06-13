defmodule Workbooks.Reclaim.VlangVpmTest do
  @moduledoc """
  RECLAIM (durable) — `vlang vpm` (V package manager).

  resolved.json reclaim recipe: vpm's entire job is "resolve a module name to its git URL via the VPM registry
  API, then fetch the module source". Upstream vpm shells out to git via os.execute_opt() (fork/exec, blocked
  in-sandbox) and has no internal HTTP client. The reclaim wraps the brokered `http` transport as a vpm shim:
    GET https://vpm.vlang.io/api/packages/<name>  -> parse JSON .url
    -> derive codeload tarball URL (https://codeload.github.com/<owner>/<repo>/tar.gz/refs/heads/master)
    -> http GET it -> unpack into ~/.vmodules/<name>
  vpm does NOT itself invoke a compiler, so its capability is reproduced END-TO-END (resolve -> fetch ->
  unpack) without any fork/exec.

  This test is SELF-CONTAINED: it registers its own `:pynet` vpm shim inline, scoped to
  vpm.vlang.io + codeload.github.com (default-deny everything else), not via Workbooks.BrokeredTools.

  What it proves empirically:
    - the VPM registry API resolves a real module name -> its github URL over brokered HTTPS,
    - the codeload tarball is fetched over brokered HTTPS, and
    - it unpacks into ~/.vmodules/<name> with V source files (`.v`) actually on disk in-sandbox.

  HONEST SCOPE: this reproduces vpm's whole fetch/install job (resolve+fetch+unpack). Building the fetched V
  module would need the V compiler (separate, not part of vpm's job) — vpm itself never compiles.
  """
  use ExUnit.Case, async: false
  alias Workbooks.CommandRegistry

  # vpm shim: resolve -> derive codeload URL -> fetch tarball -> unpack into ~/.vmodules/<name>, then list
  # the .v files it extracted. Registered INLINE so the test is self-contained.
  @vpm ~S"""
  import sys, io, tarfile, os, glob, re
  if len(sys.argv) < 2:
      sys.stderr.write("usage: vpm MODULE\n"); sys.exit(2)
  mod = sys.argv[1]
  import requests, urllib.error
  try:
      r = requests.get("https://vpm.vlang.io/api/packages/%s" % mod)
      if r.status_code != 200:
          sys.stderr.write("registry: not found %s (%d)\n" % (mod, r.status_code)); sys.exit(3)
      meta = r.json()
      url = meta.get("url") or ""
      print("RESOLVED", mod, "->", url)
      m = re.search(r"github\.com[:/]+([^/]+)/([^/.]+)", url)
      if not m:
          sys.stderr.write("cannot derive github owner/repo from %s\n" % url); sys.exit(4)
      owner, repo = m.group(1), m.group(2)
      tarball = None; blob = None
      for branch in ("master", "main"):
          tb = "https://codeload.github.com/%s/%s/tar.gz/refs/heads/%s" % (owner, repo, branch)
          rr = requests.get(tb)
          if rr.status_code == 200:
              tarball = tb; blob = rr.content; break
      if blob is None:
          sys.stderr.write("codeload fetch failed for %s/%s\n" % (owner, repo)); sys.exit(5)
      print("FETCHED", tarball, len(blob), "bytes")
      dest = "/b/.vmodules/%s" % mod
      os.makedirs(dest, exist_ok=True)
      with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tf:
          members = tf.getmembers()
          # strip the top-level "<repo>-<branch>/" dir
          for mem in members:
              parts = mem.name.split("/", 1)
              if len(parts) == 2 and parts[1]:
                  mem.name = parts[1]
                  tf.extract(mem, dest)
      vfiles = glob.glob(os.path.join(dest, "**", "*.v"), recursive=True)
      print("UNPACKED", dest, "vfiles=%d" % len(vfiles))
      for f in sorted(vfiles)[:5]:
          print("VFILE", os.path.relpath(f, dest))
      sys.exit(0 if vfiles else 6)
  except urllib.error.URLError as e:
      sys.stderr.write("error: %s\n" % e.reason); sys.exit(1)
  except Exception as e:
      import traceback; traceback.print_exc(); sys.exit(1)
  """

  @vpm_scope ["vpm.vlang.io", "*.vlang.io", "codeload.github.com"]

  setup_all do
    if "python" not in CommandRegistry.list(), do: Workbooks.Pallet.seed_one("python")
    :ok = CommandRegistry.register_pynet("reclaim-vpm", @vpm, :argv, %{allow: @vpm_scope})
    :ok
  end

  @tag :netdeps
  @tag timeout: 240_000
  test "vpm end-to-end: resolve module via VPM registry, fetch codeload tarball, unpack .v sources" do
    # `markdown` is a long-standing, small, pure-V module in the VPM registry (vlang/markdown on github).
    # Try a couple of known-registered modules so the test isn't brittle to a single repo's availability.
    out =
      Enum.reduce_while(["markdown", "pcre", "vsl"], nil, fn mod, _acc ->
        case CommandRegistry.run_status("reclaim-vpm", "", [mod]) do
          {:ok, body, 0} -> {:halt, body}
          _ -> {:cont, nil}
        end
      end)
      |> case do
        nil -> flunk("no VPM module resolved+fetched+unpacked (registry/codeload availability)")
        body -> body
      end

    # the registry resolved a name to a github url
    assert out =~ ~r/RESOLVED \w+ -> .*github\.com/, "expected registry resolution, got:\n#{out}"
    # the codeload tarball was actually fetched (real bytes)
    assert out =~ ~r/FETCHED .*codeload\.github\.com.* \d+ bytes/, "expected codeload fetch, got:\n#{out}"
    # it unpacked V source files onto disk in ~/.vmodules/<name>
    assert out =~ ~r/UNPACKED .*\.vmodules.* vfiles=[1-9]/, "expected unpacked .v files, got:\n#{out}"
    assert out =~ ~r/VFILE .*\.v/, "expected at least one .v source file, got:\n#{out}"
  end
end
