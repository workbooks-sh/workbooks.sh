defmodule Workbooks.Reclaim.GitTest do
  @moduledoc """
  RECLAIM DURABILITY TEST — git, in the WASM sandbox.

  resolved.json claim (two layers, both must hold):
    (1) LOCAL plumbing: dulwich (pure-Python wheel) installed via the brokered wheel/zipimport path gives
        git object ops with ZERO subprocess — init/add/commit/log-walk via the low-level object API
        (dulwich.objects Blob/Tree/Commit + Repo.refs). (porcelain.* spawns a process → must avoid.)
    (2) NETWORK clone/fetch: speak git smart-HTTP over the brokered requests transport — GET
        <repo>/info/refs?service=git-upload-pack, parse the ref advert, build want/deepen/done with
        dulwich.protocol.pkt_line, POST to /git-upload-pack, demux the side-band pkt-line packfile,
        add_thin_pack it into a Repo.object_store, walk the commit tree to materialize a file.

  SELF-CONTAINED: registers a `git`-class :pynet command inline with an :allow scope spanning pypi (to fetch
  the dulwich wheel) + github.com/codeload.github.com (the forge). The whole script — wheel install, local
  object plumbing, and the smart-HTTP shallow clone — lives in this test file, exactly the wiring resolved.json
  says is "the only wiring needed to ship".

  HONESTY NOTES baked into the assertions:
    * LOCAL plumbing test runs OFFLINE except for the one dulwich wheel fetch — it proves real git objects
      (a commit whose tree maps a filename→blob, reachable via the refs/log walk), not a toy.
    * NETWORK test actually retrieves a packfile from GitHub over smart-HTTP and materializes a known file's
      content. If GitHub changes its smart-HTTP framing or the repo, this FAILS loudly (no silent pass).
  """
  use ExUnit.Case, async: false
  alias Workbooks.CommandRegistry

  @scope ["pypi.org", "files.pythonhosted.org", "*.pythonhosted.org", "github.com", "codeload.github.com"]

  # Shared prelude: install a pure-python wheel (PACKAGE) by downloading it over the brokered requests
  # transport and zipimporting it (a wheel IS a zip → straight onto sys.path), mirroring pip-run. Returns the
  # installed version. Used to bring dulwich (+ typing_extensions) into the guest.
  @install_prelude ~S"""
  import sys, re, requests
  def _install(name):
      d = requests.get("https://pypi.org/pypi/%s/json" % name).json()
      ver = d["info"]["version"]; wheel = None
      for f in d.get("releases", {}).get(ver, []):
          if f.get("packagetype") == "bdist_wheel" and "py3-none-any" in f.get("filename",""):
              wheel = f["url"]; break
      if not wheel:
          raise RuntimeError("no pure-python wheel for %s" % name)
      blob = requests.get(wheel).content
      path = "/b/%s.whl" % name.replace("-","_")
      open(path,"wb").write(blob)
      sys.path.insert(0, path)
      return ver
  """

  # ── (1) LOCAL PLUMBING ──────────────────────────────────────────────────────
  @local_tool @install_prelude <> ~S"""
  _install("typing_extensions")
  dv = _install("dulwich")
  sys.stderr.write("dulwich %s\n" % dv)

  import os
  os.makedirs("/b/repo", exist_ok=True)
  from dulwich.repo import Repo
  from dulwich.objects import Blob, Tree, Commit
  import time

  repo = Repo.init("/b/repo")
  store = repo.object_store

  # build a blob -> tree -> commit entirely via the low-level object API (no porcelain, no subprocess)
  blob = Blob.from_string(b"hello from the wasm sandbox\n")
  store.add_object(blob)
  tree = Tree()
  tree.add(b"greeting.txt", 0o100644, blob.id)
  store.add_object(tree)

  c = Commit()
  c.tree = tree.id
  c.author = c.committer = b"WB <wb@example.com>"
  c.author_time = c.commit_time = int(time.time())
  c.author_timezone = c.commit_timezone = 0
  c.encoding = b"UTF-8"
  c.message = b"reclaim: local git plumbing in-sandbox\n"
  store.add_object(c)
  repo.refs[b"refs/heads/master"] = c.id

  # walk the log via the refs (read it back as git would)
  head = repo.refs[b"refs/heads/master"]
  walked = repo.get_object(head)
  assert walked.message == b"reclaim: local git plumbing in-sandbox\n"
  # resolve the tree entry -> blob content
  t = repo.get_object(walked.tree)
  mode, sha = t[b"greeting.txt"]
  content = repo.get_object(sha).as_raw_string()
  print("HEAD", head.decode())
  print("MSG", walked.message.decode().strip())
  print("FILE", content.decode().strip())
  sys.exit(0)
  """

  # ── (2) NETWORK: smart-HTTP shallow clone ───────────────────────────────────
  # Clone a TINY well-known public repo (octocat/Hello-World) and materialize its README.
  @clone_tool @install_prelude <> ~S"""
  _install("typing_extensions")
  _install("dulwich")
  import requests
  from dulwich.protocol import pkt_line
  from dulwich.repo import Repo
  import os, re

  base = "https://github.com/octocat/Hello-World.git"

  # 1) ref advertisement
  r = requests.get(base + "/info/refs?service=git-upload-pack")
  if r.status_code != 200:
      raise RuntimeError("info/refs HTTP %d" % r.status_code)
  adv = r.content
  # find HEAD sha (first 40-hex after the service pkt)
  m = re.search(rb"([0-9a-f]{40}) HEAD", adv)
  if not m:
      m = re.search(rb"([0-9a-f]{40}) refs/heads/master", adv)
  want = m.group(1).decode()
  sys.stderr.write("want %s\n" % want)

  # 2) build want/deepen/done request
  body = b""
  body += pkt_line(("want %s multi_ack_detailed side-band-64k thin-pack ofs-delta\n" % want).encode())
  body += pkt_line(b"deepen 1\n")
  body += b"0000"
  body += pkt_line(b"done\n")

  r2 = requests.post(base + "/git-upload-pack", data=body,
                     headers={"Content-Type":"application/x-git-upload-pack-request"})
  if r2.status_code != 200:
      raise RuntimeError("upload-pack HTTP %d" % r2.status_code)
  resp = r2.content

  # 3) demux side-band pkt-lines across the WHOLE buffer; band 1 = packfile bytes
  pack = b""
  i = 0
  n = len(resp)
  while i + 4 <= n:
      ln = int(resp[i:i+4], 16)
      if ln == 0:
          i += 4
          continue
      chunk = resp[i+4:i+ln]
      i += ln
      if not chunk:
          continue
      band = chunk[0]
      if band == 1:
          pack += chunk[1:]
      # band 2 = progress, band 3 = error -> ignore
  if not pack.startswith(b"PACK"):
      raise RuntimeError("no PACK in response (got %d bytes, first=%r)" % (len(pack), pack[:8]))
  sys.stderr.write("PACK %d bytes\n" % len(pack))

  # 4) add the pack to a fresh repo object store, walk the wanted commit's tree
  os.makedirs("/b/clone", exist_ok=True)
  repo = Repo.init("/b/clone")
  from io import BytesIO
  repo.object_store.add_thin_pack(BytesIO(pack).read, None)

  commit = repo.get_object(want.encode())
  tree = repo.get_object(commit.tree)
  # octocat/Hello-World has a README at root
  names = [name.decode() for name, mode, sha in tree.items()]
  print("TREE", ",".join(sorted(names)))
  readme_sha = None
  for name, mode, sha in tree.items():
      if name.lower().startswith(b"readme"):
          readme_sha = sha; break
  if not readme_sha:
      raise RuntimeError("no README in tree: %r" % names)
  content = repo.get_object(readme_sha).as_raw_string()
  print("README_BYTES", len(content))
  print("README_HEAD", content.decode("utf-8","replace").strip()[:40])
  sys.exit(0)
  """

  setup_all do
    if "python" not in CommandRegistry.list(), do: Workbooks.Pallet.seed_one("python")
    :ok = CommandRegistry.register_pynet("git-local", @local_tool, :argv, %{allow: @scope})
    :ok = CommandRegistry.register_pynet("git-clone", @clone_tool, :argv, %{allow: @scope})
    :ok
  end

  @tag :netdeps
  @tag timeout: 300_000
  test "LOCAL plumbing — dulwich object API builds a real commit (tree→blob) walkable via refs, no subprocess" do
    assert {:ok, out, 0} = CommandRegistry.run_status("git-local", "", []),
           "git-local did not exit 0"

    assert out =~ ~r/HEAD [0-9a-f]{40}/, "no 40-hex HEAD sha:\n#{out}"
    assert out =~ "MSG reclaim: local git plumbing in-sandbox"
    assert out =~ "FILE hello from the wasm sandbox",
           "the blob content didn't round-trip through tree+commit:\n#{out}"
  end

  @tag :netdeps
  @tag timeout: 300_000
  test "NETWORK — smart-HTTP shallow clone of a real GitHub repo materializes a file from the packfile" do
    assert {:ok, out, 0} = CommandRegistry.run_status("git-clone", "", []),
           "git-clone did not exit 0"

    assert out =~ ~r/TREE .*[Rr][Ee][Aa][Dd][Mm][Ee]/, "tree had no README:\n#{out}"
    assert out =~ ~r/README_BYTES \d+/, "no README bytes materialized:\n#{out}"

    # the README must be non-empty real content pulled from the packfile
    [_, n] = Regex.run(~r/README_BYTES (\d+)/, out)
    assert String.to_integer(n) > 0, "empty README — packfile not actually materialized:\n#{out}"
  end
end
