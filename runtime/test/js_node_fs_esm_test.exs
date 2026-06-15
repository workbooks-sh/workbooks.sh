defmodule Workbooks.JsNodeFsEsmTest do
  @moduledoc """
  Headless-JS path (wb-b9xv) — the two top CODE walls the probe hit on StarlingMonkey, proven on the live
  engine:

  (1) BROKERED FS — the Javy `fs` shim is dead on SM (no `Javy.VFS`). `require('node:fs')` /
      `require('fs/promises')` on this lane route over a guest `fetch()` to the pinned `wb-exec.internal`
      sentinel → `POST /__wb/fs`, token-gated AND CONFINED to the grant's `:workdir`. A JS program does
      `writeFileSync` then `readFileSync` and the bytes ROUND-TRIP through the host broker, landing as a real
      file INSIDE the workdir (verified host-side) and nowhere else. A path that escapes the workdir (`..`,
      absolute) is refused (EACCES) — NO arbitrary host FS reach.

  (2) ESM-EVAL — the prelude is CJS; a real bundle is ESM with `import { createRequire } from 'module'`,
      `createRequire(import.meta.url)` (×N) + `import.meta.url`. The host ESM->CJS rewrite + the prelude's
      `node:module`/`import.meta` stubs let such a module LOAD and run on the classic-eval lane.

  Both keep no-native-exec + workdir confinement. `:build` — needs the SM eval-host
  (build/cache/jsengine/eval-host-023.wasm); skips otherwise.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{JsEngine, ExecLoopback}

  setup_all do
    # the fs/exec loopback listener must be up (the SM lane fetches its sentinel). Start it directly so the
    # test doesn't depend on WB_HARNESS app supervision; idempotent if already started.
    System.put_env("WB_HARNESS", "1")
    {:ok, _} = Task.start(fn -> ExecLoopback.start_listener(); Process.sleep(:infinity) end)
    wait_for_loopback()
    System.delete_env("WB_HARNESS")
    {:ok, ready?: match?({:ok, _}, JsEngine.build_host())}
  end

  defp wait_for_loopback(tries \\ 200) do
    cond do
      tries <= 0 -> :ok
      match?(p when is_integer(p), :persistent_term.get({ExecLoopback, :port}, nil)) -> :ok
      true -> Process.sleep(10); wait_for_loopback(tries - 1)
    end
  end

  defp workdir do
    d = Path.join(System.tmp_dir!(), "wb-fs-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(d) end)
    d
  end

  defp skip?(false), do: (IO.puts("\n[skip] SM eval-host not built"); true)
  defp skip?(true), do: false

  # ── (1) brokered fs round-trip, confined to the workdir ────────────────────────────────────────

  @tag :build
  @tag timeout: 120_000
  test "GRANTED — writeFileSync + readFileSync round-trip through the broker, confined to workdir",
       %{ready?: ready?} do
    if not skip?(ready?) do
      dir = workdir()

      # *Sync on SM resolves to a Promise (the documented SM adjustment, same as child_process) — await it.
      src = ~S"""
      const fs = require('node:fs');
      await fs.writeFileSync('hello.txt', 'round-trip-payload');
      const back = await fs.readFileSync('hello.txt', 'utf8');
      process.stdout.write('READ:' + back);
      const exists = await fs.existsSync('hello.txt');
      process.stdout.write('|EXISTS:' + exists);
      const st = await fs.statSync('hello.txt');
      process.stdout.write('|SIZE:' + st.size + '|ISFILE:' + st.isFile());
      """

      assert {:ok, %{stdout: out, exit_code: 0}} =
               JsEngine.run_node(src, fs: [workdir: dir, principal: "fs-tenant"])

      assert out =~ "READ:round-trip-payload"
      assert out =~ "EXISTS:true"
      assert out =~ "SIZE:18"
      assert out =~ "ISFILE:true"

      # the write landed as a REAL file INSIDE the workdir, and nowhere else (host-side proof of confinement).
      assert File.read!(Path.join(dir, "hello.txt")) == "round-trip-payload"
    end
  end

  @tag :build
  @tag timeout: 120_000
  test "fs/promises mkdir + readdir round-trip inside the workdir", %{ready?: ready?} do
    if not skip?(ready?) do
      dir = workdir()

      src = ~S"""
      const fsp = require('fs/promises');
      await fsp.mkdir('sub', { recursive: true });
      await fsp.writeFile('sub/a.txt', 'A');
      await fsp.writeFile('sub/b.txt', 'B');
      const entries = await fsp.readdir('sub');
      process.stdout.write('ENTRIES:' + entries.sort().join(','));
      """

      assert {:ok, %{stdout: out, exit_code: 0}} =
               JsEngine.run_node(src, fs: [workdir: dir, principal: "fs-tenant"])

      assert out =~ "ENTRIES:a.txt,b.txt"
      assert File.dir?(Path.join(dir, "sub"))
    end
  end

  @tag :build
  @tag timeout: 120_000
  test "CONFINED — a path escaping the workdir is refused (no arbitrary host FS)", %{ready?: ready?} do
    if not skip?(ready?) do
      dir = workdir()

      # try to read /etc/passwd via a traversal — must be refused (EACCES), never reaching the host file.
      src = ~S"""
      const fs = require('node:fs');
      try {
        const leak = await fs.readFileSync('../../../../../../etc/passwd', 'utf8');
        process.stdout.write('LEAK:' + leak.slice(0, 8));
      } catch (e) {
        process.stdout.write('DENIED:' + e.code);
      }
      """

      assert {:ok, %{stdout: out}} =
               JsEngine.run_node(src, fs: [workdir: dir, principal: "fs-tenant"])

      assert out =~ "DENIED:"
      refute out =~ "LEAK:"
      refute out =~ "root:"
    end
  end

  @tag :build
  @tag timeout: 120_000
  test "NO GRANT — require('node:fs') is unavailable without an fs grant", %{ready?: ready?} do
    if not skip?(ready?) do
      # no fs: opt → the SM fs shim isn't registered → require('node:fs') throws on line 1 (no silent cap).
      src = ~S"""
      const fs = require('node:fs');
      process.stdout.write('LOADED');
      """

      assert {:error, {:node_eval_failed, msg}} = JsEngine.run_node(src)
      assert msg =~ "Cannot find module"
    end
  end

  # ── (2) ESM-eval + createRequire + import.meta.url ─────────────────────────────────────────────

  @tag :build
  @tag timeout: 120_000
  test "ESM module with createRequire(import.meta.url) ×N loads and runs", %{ready?: ready?} do
    if not skip?(ready?) do
      dir = workdir()

      # A real-bundle-shaped ESM head: import createRequire from 'module', build require off import.meta.url
      # (three times, as bundlers emit), use it for a builtin (node:path) AND the granted fs, plus a named +
      # default import and a top-level export. The host ESM->CJS rewrite + prelude stubs must make it run.
      src = ~S"""
      import { createRequire } from 'module';
      import * as nodePath from 'node:path';
      const require = createRequire(import.meta.url);
      const require2 = createRequire(import.meta.url);
      const require3 = createRequire(import.meta.url);
      const path = require('node:path');
      const fs = require2('node:fs');
      const url = require3('node:url');
      export const joined = path.join('a', 'b', 'c');
      await fs.writeFileSync('esm.txt', 'esm-' + joined);
      const back = await fs.readFileSync('esm.txt', 'utf8');
      process.stdout.write('JOINED:' + joined);
      process.stdout.write('|NS:' + nodePath.join('x', 'y'));
      process.stdout.write('|META:' + (typeof import.meta.url === 'string'));
      process.stdout.write('|FSBACK:' + back);
      """

      assert {:ok, %{stdout: out, exit_code: 0}} =
               JsEngine.run_node(src, fs: [workdir: dir, principal: "esm-tenant"])

      assert out =~ "JOINED:a/b/c"
      assert out =~ "NS:x/y"
      assert out =~ "META:true"
      assert out =~ "FSBACK:esm-a/b/c"
      assert File.read!(Path.join(dir, "esm.txt")) == "esm-a/b/c"
    end
  end
end
