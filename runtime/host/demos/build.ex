defmodule Workbooks.Demos.Build do
  @moduledoc "Demos for the build/orchestration path: tangle+build per language, DAG, compose, workflows, commands, shell, sandbox."

  # A JS component in Javy I/O form (reads stdin, writes stdout).
  @build_demo """
  <work-flow title="Build demo">
    <work-component title="Uppercase" lang="js">
  const buf = new Uint8Array(4096); let n, t = 0;
  while ((n = Javy.IO.readSync(0, buf.subarray(t))) > 0) t += n;
  const s = new TextDecoder().decode(buf.subarray(0, t)).trim();
  Javy.IO.writeSync(1, new TextEncoder().encode(JSON.stringify({upper: s.toUpperCase()})));
    </work-component>
  </work-flow>
  """

  @doc "Tangle→build→run demo: a JS component compiled to real WASM and executed."
  def demo_build do
    [{name, lang, build}] = Workbooks.PackageManager.tangle(@build_demo)

    case build do
      {:ok, wasm, how} ->
        out = Workbooks.PackageManager.run(wasm, "hello workbook") |> String.trim()
        %{component: name, lang: lang, built: how, wasm: Path.basename(wasm), output: out}

      other ->
        %{component: name, lang: lang, error: other}
    end
  end

  # Two JS filters wired by the work-component edge u:json — Upper's output feeds Count.
  @chain """
  <work-flow title="Chain">
    <work-component title="Upper" lang="js" out="u:json">
  const b=new Uint8Array(4096);let n,t=0;while((n=Javy.IO.readSync(0,b.subarray(t)))>0)t+=n;
  const s=new TextDecoder().decode(b.subarray(0,t)).trim();
  Javy.IO.writeSync(1,new TextEncoder().encode(JSON.stringify({upper:s.toUpperCase()})));
    </work-component>
    <work-component title="Count" lang="js" in="u:json">
  const b=new Uint8Array(4096);let n,t=0;while((n=Javy.IO.readSync(0,b.subarray(t)))>0)t+=n;
  const d=JSON.parse(new TextDecoder().decode(b.subarray(0,t)).trim());
  Javy.IO.writeSync(1,new TextEncoder().encode(JSON.stringify({len:d.upper.length})));
    </work-component>
  </work-flow>
  """

  @doc "DAG demo: Upper → Count; the runtime pipes A's output into B's input along the edge."
  def demo_dag, do: Workbooks.PackageManager.run_dag(@chain, "hello")

  # One workbook, two languages: Rust (reverse) + TypeScript (length).
  @polyglot """
  <work-flow title="Polyglot">
    <work-component title="Reverse" lang="rust">
  use std::io::{Read,Write};
  fn main(){let mut s=String::new();std::io::stdin().read_to_string(&mut s).unwrap();let r:String=s.trim().chars().rev().collect();std::io::stdout().write_all(r.as_bytes()).unwrap();}
    </work-component>
    <work-component title="Measure" lang="ts">
  const b=new Uint8Array(4096);let n,t=0;while((n=(globalThis as any).Javy.IO.readSync(0,b.subarray(t)))>0)t+=n;
  const s: string = new TextDecoder().decode(b.subarray(0,t)).trim();
  (globalThis as any).Javy.IO.writeSync(1,new TextEncoder().encode(JSON.stringify({len:s.length})));
    </work-component>
  </work-flow>
  """

  @doc "Polyglot build demo: a Rust + a TypeScript component, each compiled to real WASM and run."
  def demo_polyglot do
    Workbooks.PackageManager.tangle(@polyglot)
    |> Enum.map(fn
      {name, lang, {:ok, wasm, how}} ->
        %{name: name, lang: lang, how: how, output: Workbooks.PackageManager.run(wasm, "hello") |> String.trim()}

      {name, lang, other} ->
        %{name: name, lang: lang, error: other}
    end)
  end

  # Mode 2: a component that references a REAL project dir.
  @dir_workbook """
  <work-flow title="Real project">
    <work-component title="Reverser" lang="rust" dir="examples/reverser"></work-component>
  </work-flow>
  """

  @doc "Referenced-dir demo: build a real on-disk Rust crate (with a cargo dep) → WASM → run."
  def demo_dir_build do
    [{name, lang, result}] = Workbooks.PackageManager.tangle(@dir_workbook)

    case result do
      {:ok, wasm, how} ->
        %{name: name, lang: lang, how: how, output: Workbooks.PackageManager.run(wasm, "hello") |> String.trim()}

      other ->
        %{name: name, lang: lang, error: other}
    end
  end

  # A Go component (TinyGo → wasm, WASI stdio): reverse stdin.
  @go_workbook """
  <work-flow title="Go demo">
    <work-component title="Reverse" lang="go">
  package main
  import ("bufio";"os")
  func main(){ b,_ := bufio.NewReader(os.Stdin).ReadString(0); r := []rune(b); for i,j:=0,len(r)-1;i<j;i,j=i+1,j-1 {r[i],r[j]=r[j],r[i]}; os.Stdout.WriteString(string(r)) }
    </work-component>
  </work-flow>
  """

  @doc "Go build demo: a Go component compiled to real WASM by TinyGo and run."
  def demo_go do
    [{name, lang, result}] = Workbooks.PackageManager.tangle(@go_workbook)

    case result do
      {:ok, wasm, how} ->
        %{component: name, lang: lang, built: how, output: Workbooks.PackageManager.run(wasm, "workbook") |> String.trim()}

      other ->
        %{component: name, lang: lang, error: other}
    end
  end

  # A workflow IS the DAG: tasks (components) + edges + nested sub-workflows.
  @workflow_demo """
  <work-flow title="Pipeline" scheduled="2026-06-07 06:00 +1d">
    <work-component title="Upper" lang="js" out="up:json">
  const b=new Uint8Array(4096);let n,t=0;while((n=Javy.IO.readSync(0,b.subarray(t)))>0)t+=n;
  const s=new TextDecoder().decode(b.subarray(0,t)).trim();
  Javy.IO.writeSync(1,new TextEncoder().encode(JSON.stringify({upper:s.toUpperCase()})));
    </work-component>
    <work-component title="Count" lang="js" in="up:json">
  const b=new Uint8Array(4096);let n,t=0;while((n=Javy.IO.readSync(0,b.subarray(t)))>0)t+=n;
  const d=JSON.parse(new TextDecoder().decode(b.subarray(0,t)).trim());
  Javy.IO.writeSync(1,new TextEncoder().encode(JSON.stringify({len:d.upper.length})));
    </work-component>
    <work-flow title="Audit">
      <work-component title="Echo" lang="js">
  const b=new Uint8Array(4096);let n,t=0;while((n=Javy.IO.readSync(0,b.subarray(t)))>0)t+=n;
  const s=new TextDecoder().decode(b.subarray(0,t)).trim();
  Javy.IO.writeSync(1,new TextEncoder().encode("audited:"+s));
      </work-component>
    </work-flow>
  </work-flow>
  """

  @doc """
  Workflow demo (wb-11ck.47): a workflow IS the DAG — no separate board. Run
  Pipeline (Upper→Count piped) + its nested Audit sub-workflow → a run record
  (each task's output + the schedule), executed natively from the workbook HTML.
  """
  def demo_workflow do
    [pipeline] = Workbooks.Workflow.run(@workflow_demo, "hello world")

    %{
      workflow: pipeline.workflow,
      schedule: pipeline.schedule,
      tasks: pipeline.tasks,
      audit: hd(pipeline.sub_workflows) |> Map.take([:workflow, :tasks])
    }
  end

  @js_workbook ~S"""
  export function run(input) {
    const d = JSON.parse(input);
    return JSON.stringify({ items: d.items.length, name: (d.name || "").toUpperCase() });
  }
  """

  @doc """
  JS Workbook component demo (wb-11ck.35): author a Workbook in JS — a module that
  exports `run` — componentize it to a real WIT-typed Component via jco
  (StarlingMonkey), load it into an Instance, and call run. Workbooks aren't
  Rust-only; the common language works end to end on the same Component substrate.
  """
  def demo_js_workbook do
    case Workbooks.PackageManager.build_engine_js(@js_workbook) do
      {:ok, wasm, how} ->
        id = "jswb-#{System.unique_integer([:positive])}"
        {:ok, _} = Workbooks.Instance.Supervisor.start_instance(id, File.read!(wasm), policy: :minimal)
        {:ok, out} = Workbooks.Instance.call(id, "run", [~s({"items":[1,2,3,4],"name":"acme"})])
        %{built: how, output: Jason.decode!(out)}

      other ->
        %{error: other}
    end
  end

  # A C component (zig cc → wasm32-wasi, WASI stdio): uppercase stdin.
  @c_workbook """
  <work-flow title="C demo">
    <work-component title="Upper" lang="c">
  #include <stdio.h>
  #include <ctype.h>
  int main(void){int c;while((c=getchar())!=EOF)putchar(toupper(c));return 0;}
    </work-component>
  </work-flow>
  """

  @doc "C build demo (wb-11ck.42): a C component compiled to real WASM by zig cc and run."
  def demo_c do
    [{name, lang, result}] = Workbooks.PackageManager.tangle(@c_workbook)

    case result do
      {:ok, wasm, how} ->
        %{component: name, lang: lang, built: how, output: Workbooks.PackageManager.run(wasm, "hello from a c workbook") |> String.trim()}

      other ->
        %{component: name, lang: lang, error: other}
    end
  end

  @node_workbook ~S"""
  export function run(input) {
    const buf = Buffer.from(input);
    return JSON.stringify({ bytes: buf.length, platform: process.platform, echo: input.toUpperCase() });
  }
  """

  @doc """
  Node-compat demo (wb-11ck.37, incremental): a Node-style JS Workbook that uses
  `Buffer` + `process` is built with the Node-compat preamble and run in an
  Instance. Proves the common Node globals work on the WASM substrate (fs→VFS /
  net→net-fetch are the next slices).
  """
  def demo_node_compat do
    case Workbooks.PackageManager.build_node_js(@node_workbook) do
      {:ok, wasm, _} ->
        id = "node-#{System.unique_integer([:positive])}"
        {:ok, _} = Workbooks.Instance.Supervisor.start_instance(id, File.read!(wasm), policy: :minimal)
        {:ok, out} = Workbooks.Instance.call(id, "run", ["hello node"])
        %{node_compat: :ran, output: Jason.decode!(out)}

      other ->
        %{error: other}
    end
  end

  @doc """
  Build-isolation demo — RETIRED (wb-9ja). It demonstrated `Workbooks.Sandbox`
  (the native bwrap/seatbelt isolator), which was DELETED: the build path no
  longer runs ANY native compiler, so there is no native isolator to demo. The
  real isolation now IS the wasm sandbox (wasmtime running `.wasm`), shown by
  `demo_shell` / the language-lane demos. Returns a static note.
  """
  def demo_sandbox do
    %{retired: true, note: "native build sandbox removed (wb-9ja) — compilation is in-wasm only"}
  end

  @doc "Pipe-shell demo (wb-11ck.20): a bash-style pipeline of in-WASM commands, no OS fork."
  def demo_shell do
    json = ~s|{"users":[{"name":"ada"},{"name":"grace"},{"name":"alan"}]}|

    %{
      names: Workbooks.Shell.run("jq .users[].name", json),
      pipeline: Workbooks.Shell.run("jq .users[].name | grep a | upper", json)
    }
  end

  # Two JS components componentized + composed into one (structural bundle).
  @compose_demo """
  <work-flow title="Compose demo">
    <work-component title="Uppercase" lang="js">
  const buf = new Uint8Array(4096); let n, t = 0;
  while ((n = Javy.IO.readSync(0, buf.subarray(t))) > 0) t += n;
  const s = new TextDecoder().decode(buf.subarray(0, t)).trim();
  Javy.IO.writeSync(1, new TextEncoder().encode(JSON.stringify({upper: s.toUpperCase()})));
    </work-component>
    <work-component title="Length" lang="js">
  const buf = new Uint8Array(4096); let n, t = 0;
  while ((n = Javy.IO.readSync(0, buf.subarray(t))) > 0) t += n;
  const s = new TextDecoder().decode(buf.subarray(0, t)).trim();
  Javy.IO.writeSync(1, new TextEncoder().encode(JSON.stringify({len: s.length})));
    </work-component>
  </work-flow>
  """

  @doc "Compose demo: componentize TWO Javy core modules, then `wac compose` into one component."
  def demo_compose do
    pm = Workbooks.PackageManager

    components =
      for {_name, "js", {:ok, core, _}} <- pm.tangle(@compose_demo) do
        {:ok, comp, _} = pm.componentize(core)
        comp
      end

    {:ok, composed, how} = pm.compose(components)
    %{components: length(components), composed: Path.basename(composed), how: how, valid: pm.validate_component(composed)}
  end

  # Two JS components for the TYPED contract: A exports `stage`, B imports `stage.apply`.
  @typed_compose_demo """
  <work-flow title="Typed compose demo">
    <work-component title="Upper" lang="js" out="t:string">
  export const stage = { apply(input) { return input.toUpperCase(); } };
    </work-component>
    <work-component title="Label" lang="js" in="t:string">
  import { apply } from 'wb:pipe/stage';
  export function run(input) { const u = apply(input); return u + " (len=" + u.length + ")"; }
    </work-component>
  </work-flow>
  """

  @doc "Typed-compose demo: lower the work-component edge into WIT, componentize via jco, `wac plug` A→B into one typed component."
  def demo_typed_compose do
    pm = Workbooks.PackageManager
    {:ok, composed, how} = pm.typed_compose(@typed_compose_demo)
    %{composed: Path.basename(composed), how: how, valid: pm.validate_component(composed)}
  end
end
