defmodule Nexus.Compile do
  @moduledoc """
  Route a parsed unit to its artifact — the one place placement becomes execution:

      resource         → a typed struct           (the shape; persisted via `Nexus.Store`)
      server           → a native BEAM module      (`Nexus.Unit`)
      client / foreign → a wasm component          (the compilers → `Nexus.Sandbox`)

  Server units are native Elixir — no wasm. Everything else that isn't pure data compiles to
  wasm via OUR compilers (the moat) and runs on wasmex. The compilers are *reused* from the
  existing toolchain when we wire them in; this module just routes and orchestrates.
  """

  # The real wasm COMPILE lanes (a language → wasm component). `client` is NOT here — it's a
  # render target (its body is emitted into the page verbatim by the weave/SSR, not compiled).
  # `sandbox` is NOT here either — it's a placement WRAPPER that names capability grants around an
  # INNER language (`sandbox c :name` → kind="sandbox", lang="c"); it routes to the inner lane.
  @wasm_kinds ~w(rust zig c cpp swift python js ts)

  @doc "Compile one parsed `:code` unit to its artifact, tagged by lane."
  def unit(%{type: :code, kind: kind} = node) do
    cond do
      kind == "resource" -> {:resource, Nexus.Resource.compile(node)}
      kind == "server" -> {:beam, Nexus.Unit.compile(node)}
      kind == "worker" -> {:worker, Nexus.Worker.compile(node)}
      kind == "agent" -> {:agent, Nexus.Agent.def_from_unit(node)}
      kind == "hook" -> {:hook, Nexus.Hook.compile(node)}
      kind == "flow" -> {:flow, Nexus.Flow.compile(node)}
      kind == "check" -> {:check, Nexus.Checks.parse(node)}
      kind == "toolkit" -> {:toolkit, Nexus.Toolkit.build(node)}
      # The wasm lanes shell heavy wasmtime compiler processes (~450–900MB, ~7–20s, near-constant
      # regardless of source size — it's the compiler+stdlib working set, not the user's code). So we
      # NEVER compile the same thing twice: `cached/2` content-addresses the result, and only a COLD
      # MISS runs the real build (gated by compile-concurrency). A hit is a hash lookup → the same
      # `.wasm` is served to every tenant/request, fleet-wide, forever. This is what makes the
      # multi-tenant server cheap: pay the gigabyte ONCE per unique program, not per call.
      # `client` — a browser island: its body IS the interface, emitted client-side by the weave
      # (reactor render.zig) / SSR verbatim. Not a wasm compile lane; the compile pipeline passes
      # it through so a `client` unit is never (mis)reported as an unbuilt artifact.
      kind == "client" -> {:client, node.body}
      # `sandbox` — a capability-scoped wrapper around an INNER language. Route by `node.lang` to
      # that language's real lane; grant enforcement rides through the lane (c_unit/rust_unit read
      # the unit's `grant:` via Nexus.Audit) + instantiation (Nexus.Sandbox wires only granted Dock
      # imports). This is what makes "guest code → WASM with only granted powers" real.
      kind == "sandbox" -> lane(node.lang, node)
      kind in ~w(rust c cpp zig swift js ts python svelte solid) -> lane(kind, node)

      # Any remaining wasm kind has no wired lane — surface a LOUD, explicit error (never a silent
      # tuple that masquerades as an artifact). When a lane is wired, add its arm to `lane/2`.
      kind in @wasm_kinds ->
        require Logger
        Logger.error("[compile] lane not built: #{kind}:#{node.name} (#{node.lang}) — no compiler wired")
        {:error, {:unbuilt_lane, kind, node.name}}

      true ->
        {:skip, kind}
    end
  end

  def unit(_), do: {:skip, :not_a_unit}

  # Route a language to its artifact, TAGGED by execution shape so the run path knows how to invoke it:
  #   {:core, _}    — a route-(a) CORE wasm unit (wb-vhq1u) → TinyLasers.Wasm + host_call→HostDock. The
  #                   BEAM-native replacement for {:wasm}; no wasmex. c/rust/zig/swift migrate here.
  #   {:wasm, _}    — a typed wasm COMPONENT (rust/c/zig/swift, pre-flip) → Nexus.Sandbox.start + call
  #   {:command, _} — a WASI COMMAND module (js/ts/python; stdin→stdout) → Nexus.Sandbox.run_command
  #   {:client, _}  — browser JS (svelte/solid; needs a DOM) → emitted as a client island, not run server-side
  defp lane("go", node), do: {:core, cached(node, fn -> go_unit_core(node) end)}
  defp lane(l, node) when l in ~w(c cpp), do: {:core, cached(node, fn -> c_unit_core(node) end)}
  defp lane("zig", node), do: {:core, cached(node, fn -> zig_unit_core(node) end)}
  defp lane("rust", node), do: {:wasm, cached(node, fn -> rust_unit(node) end)}
  defp lane("swift", node), do: {:wasm, cached(node, fn -> swift_unit(node) end)}
  defp lane("js", node), do: {:command, cached(node, fn -> js_unit(node) end)}
  defp lane("ts", node), do: {:command, cached(node, fn -> ts_unit(node) end)}
  # python's artifact is the shared interpreter + the unit's (dedented) source — NOT a per-unit build,
  # so it skips the wasm cache; the spec carries the source for the run path to mount.
  defp lane("python", node), do: {:command, python_unit(node)}
  defp lane("svelte", node), do: svelte_client(node)
  defp lane("solid", node), do: solid_client(node)
  defp lane(other, node), do: {:error, {:sandbox_unknown_lang, other, node.name}}

  # ── content-addressed compile cache ──────────────────────────────────────────────────────────
  # Every knob below comes from `Nexus.Config` (the `deploy` config element), never env:
  # `compile_cache?` (on/off), `compile_cache_version` (the salt — bump to invalidate the store),
  # `component_cache` (the store location). Config-as-source, not an env sidecar.

  @doc """
  Run `build` (a real wasm compile) ONLY on a cache miss; otherwise return the already-built
  component. The key is `sha256(salt + kind + name + body + grants)` — every input that changes the
  output. The store is content-addressed and shared, so identical source compiled by ANY caller hits.
  On a hit the gate is never touched (no slot, no wasmtime). Failures are NOT cached.
  """
  def cached(node, build) do
    if cache_enabled?() do
      key = cache_key(node)

      case Nexus.Compile.Store.fetch(key) do
        {:ok, path} ->
          {:ok, path}

        :miss ->
          # Miss: pay the real cost ONCE, under the concurrency gate, then store (local + remote).
          case Nexus.Wasm.Gate.with_slot(:compile, compile_share_key(node), build) do
            {:ok, comp} -> {:ok, Nexus.Compile.Store.put(key, comp)}
            other -> other
          end
      end
    else
      Nexus.Wasm.Gate.with_slot(:compile, compile_share_key(node), build)
    end
  end

  @doc false
  # The per-tenant fair-share key for the compile lane (wb-1fgl). Keyed by the OWNING WORKSPACE so one
  # tenant's compile storm can't starve another's (the gate shares slots max-min-fairly across keys).
  # Resolve the unit's source to its declared workspace subtree; fall back to the source directory,
  # then `:shared` when a unit has no source path (an ad-hoc/SSR render).
  def compile_share_key(node) do
    case Map.get(node, :src) do
      p when is_binary(p) ->
        Nexus.Config.workspaces()
        |> Enum.map(& &1.id)
        |> Enum.filter(&String.contains?(p, &1))
        |> Enum.max_by(&String.length/1, fn -> nil end)
        |> case do
          nil -> Path.dirname(p)
          ws -> ws
        end

      _ ->
        :shared
    end
  end

  defp cache_key(%{kind: k, name: n, body: b} = node) do
    grants = node |> safe_grants() |> Enum.sort() |> Enum.join(",")
    salt = Nexus.Config.compile_cache_version()
    :crypto.hash(:sha256, [salt, 0, k, 0, n, 0, b, 0, grants]) |> Base.encode16(case: :lower)
  end

  defp safe_grants(node) do
    Nexus.Audit.granted(node)
  rescue
    _ -> []
  end

  defp cache_enabled?, do: Nexus.Config.compile_cache?()

  # Mark a NUMERIC, no-arg, import-free `render` as WASHY-ELIGIBLE: write a `<comp>.washy` sidecar with
  # the render return type. The cache preserves it; SSR then runs the CORE module (which the component
  # wraps) on Washy in-process — dense, no Component Model needed for a primitive return. Anything else
  # (string/record return, params, host imports) has no marker → stays on the wasmtime component path.
  defp mark_washy({:ok, comp} = ok, world) when is_binary(comp) do
    unless world =~ ~r/\bimport\s/ do
      case Regex.run(~r/render:\s*func\(\)\s*->\s*([\w-]+)/, world) do
        [_, ret] -> if numeric_wit?(ret), do: File.write!(comp <> ".washy", ret)
        _ -> :ok
      end
    end

    ok
  end

  defp mark_washy(other, _world), do: other

  defp numeric_wit?(t), do: t in ~w(s8 u8 s16 u16 s32 u32 s64 u64 f32 f64 bool char)

  # A `rust` unit, fully automatic: derive the typed WIT world from its `pub fn` exports AND its
  # `extern "C"` host imports, then run the proven pipeline. `{:ok, component} | {:error, _}`.
  defp rust_unit(%{body: body} = node) do
    %{name: name, exports: exports, imports: imports} = rust_world(node)

    case exports do
      [] ->
        {:error, :no_exported_fns}

      _ ->
        # A host import typed by the Dock's signature if it's a known cap, else the unit's own
        # (lowered) extern signature. Caps carry the proper WIT type (e.g. `string`).
        ilines =
          Enum.map(imports, fn {f, ps, r} ->
            {wit_ident(f), Nexus.Dock.host_fn_wit(f) || "func(#{ps})#{r}"}
          end)

        elines = Enum.map(exports, fn {f, ps, r} -> {wit_ident(f), "func(#{ps})#{r}"} end)
        world = Nexus.Wit.world_from_sigs(name, ilines, elines)
        import_names = Enum.map(imports, &elem(&1, 0))
        to_component(body, Enum.map(exports, &elem(&1, 0)), world, name, import_names, crate_deps(body))
    end
  end

  # A no-libc bump allocator satisfying the component-model `cabi_realloc` (host allocates the
  # returned string here). Bump-only (never frees) — fine for a single unit invocation.
  @c_cabi_realloc """
  static unsigned char __nx_heap[262144];
  static unsigned long __nx_top = 0;
  void* cabi_realloc(void* old, unsigned long os, unsigned long al, unsigned long ns) {
    unsigned long p = (__nx_top + (al - 1)) & ~(al - 1);
    __nx_top = p + ns;
    return &__nx_heap[p];
  }
  """

  # A `c`/`cpp` unit: derive the WIT world from the C function signatures, compile (clang →
  # reactor, no command machinery), componentize (no WASI adapter needed). `{:ok, comp} | {:error}`.
  defp c_unit(%{name: name, body: body} = node) do
    exports = c_sigs(body)
    # caps come from either an explicit `extern` (the author wrote the lowered decl) OR a grant
    # (clean: `grant: [load]` and the lane injects the extern + a tidy wrapper). Both → Dock caps.
    declared = body |> c_import_names() |> Enum.filter(&Nexus.Dock.host_fn_wit/1)
    granted = node |> Nexus.Audit.granted() |> Enum.filter(&Nexus.Dock.host_fn_wit/1)
    caps = Enum.uniq(declared ++ granted)
    inject = granted -- declared

    case exports do
      [] ->
        {:error, :no_exported_fns}

      _ ->
        wname = wit_ident(name)
        ilines = Enum.map(caps, fn n -> {wit_ident(n), Nexus.Dock.host_fn_wit(n)} end)
        elines = Enum.map(exports, fn {f, ps, r} -> {wit_ident(f), "func(#{ps})#{r}"} end)
        world = Nexus.Wit.world_from_sigs(name, ilines, elines)

        # A string-RETURNING cap needs a `cabi_realloc` export (the host allocates the returned
        # string in guest memory). Inject a no-libc bump allocator + export it.
        str_ret? = Enum.any?(caps, &Nexus.Dock.returns_string?/1)
        fn_exports = Enum.map(exports, &elem(&1, 0)) ++ if(str_ret?, do: ["cabi_realloc"], else: [])

        # Grant-driven glue: extern decls (for granted-but-not-declared caps) + `nx_str` wrappers
        # (for single-string-param string-returning caps) — injected BEFORE the body so the author
        # just calls `load_s("k")` and gets a `{ptr, len}` instead of hand-rolling the ret-area.
        prelude = c_prelude(inject, caps)
        src_body = prelude <> body <> if(str_ret?, do: "\n" <> @c_cabi_realloc, else: "")

        src = Path.join(System.tmp_dir!(), "nxc_#{System.unique_integer([:positive])}.c")
        File.write!(src, src_body)

        with {:ok, core} <- Nexus.Compilers.C.compile_to_wasm(src, exports: fn_exports, allow_undefined: caps != []) do
          core = if caps != [], do: rewrite_imports(core, Path.dirname(core), caps), else: core
          Nexus.Wit.componentize(core, world, wname) |> mark_washy(world)
        end
    end
  end

  @doc """
  ROUTE (a) (wb-vhq1u): compile a `c`/`cpp` unit to a **CORE** `wasm32-wasip1` module that reaches Dock
  caps through the ONE typed `host_call` import (`tiny-lasers/docs/host-bridge-abi.md` §2/§7) — NO WIT
  component, no `componentize`, no wasmex. The core runs on `TinyLasers.Wasm`; its `host_call("dock_<op>",
  json)` routes to `TinyLasers.Wasm.HostDock` → `Dock.impls` (tenant-bound, grant-filtered).

  Returns `{:ok, core_path, exported_fn_names, string_returning_exports}`. The last element is the STRING
  MARKER (§5b): a `nx_str`-returning export is rewritten to a packed-i64 `run(...)->(ptr<<32)|len` export
  (the author's `nx_str <name>()` → `__impl_<name>`, plus a packing wrapper `<name>`), and its name lands
  in that list so the run path picks `Nexus.Wasm.Sandbox.run_str` over `run` — the type is `long long` by
  convention, indistinguishable from a real i64 without this marker.
  """
  def c_unit_core(%{body: body} = node) do
    # §5b string-return marker: rewrite each `nx_str <name>(void)` export into a packed-i64 export.
    str_exports =
      ~r/\bnx_str\s+([a-z_]\w*)\s*\(\s*(?:void)?\s*\)/
      |> Regex.scan(body)
      |> Enum.map(fn [_, n] -> n end)
      |> Enum.uniq()

    body =
      Enum.reduce(str_exports, body, fn n, b ->
        String.replace(b, ~r/\bnx_str\s+#{n}\s*\(/, "nx_str __impl_#{n}(") <>
          "\nlong long #{n}(void) { nx_str __r = __impl_#{n}(); return ((long long)(unsigned int)(unsigned long)__r.ptr << 32) | (unsigned int)__r.len; }\n"
      end)

    case c_sigs(body) do
      [] ->
        {:error, :no_exported_fns}

      exports ->
        # exported fn names (the packed `<name>`, never the renamed `__impl_<name>`) + tl_alloc (§5b).
        fn_exports =
          exports
          |> Enum.map(&elem(&1, 0))
          |> Enum.reject(&String.starts_with?(&1, "__impl_"))
          |> Kernel.++(["tl_alloc"])

        # Route (a) is GRANT-driven: the author writes `grant: [store, load]` and calls the generated
        # `store(…)`/`load(…)` wrappers — no hand-written `extern` decls (those were the WIT-import model).
        caps = node |> Nexus.Audit.granted() |> Enum.filter(&Nexus.Dock.host_fn_wit/1)

        src_body = c_hostcall_prelude(caps) <> body
        src = Path.join(System.tmp_dir!(), "nxc_core_#{System.unique_integer([:positive])}.c")
        File.write!(src, src_body)

        with {:ok, core} <- Nexus.Compilers.C.compile_to_wasm(src, exports: fn_exports, allow_undefined: true) do
          {:ok, core, fn_exports, str_exports}
        end
    end
  end

  # Route (a) C prelude: §7's ONE `host_call` extern + a shared result buffer + a typed wrapper per cap.
  # A guest calls `store("k",1,"v",1)` / `load("k",1)` (a `nx_str`) and the wrapper marshals args → a JSON
  # array and the result ← the JSON value — the typed marshaling the WIT component used to give, per §2.
  defp c_hostcall_prelude(caps) do
    extern = """
    __attribute__((import_name("host_call")))
    extern int host_call(const char* __nm, int __nl, const char* __ar, int __al, char* __out, int __oc);
    typedef struct { const char* ptr; int len; } nx_str;
    static char __hc_out[65536];
    // §5b string-RETURN support: a no-libc bump allocator so a string a unit RETURNS lives in stable guest
    // memory (the host reads it via the packed-i64 `run(...)->(ptr<<32)|len` convention). `tl_alloc` is
    // exported (added to fn_exports in c_unit_core) per the hello_bridge.c reference.
    static char __tl_heap[262144];
    static int __tl_hp = 0;
    __attribute__((export_name("tl_alloc")))
    char* tl_alloc(int __n) { char* __p = &__tl_heap[__tl_hp]; __tl_hp = (__tl_hp + __n + 7) & ~7; return __p; }
    """

    extern <> Enum.map_join(caps, "\n", &c_hostcall_wrapper/1)
  end

  @doc """
  ROUTE (a), Go: compile a `go` unit (tinygo → core `wasm32-wasi`) that reaches Dock caps through the ONE
  `//go:wasmimport env host_call` bridge — same contract as `c_unit_core`, no components. Exports are the
  body's `//go:wasmexport` funcs. `{:ok, core_path, exported_fn_names}`.
  """
  def go_unit_core(%{body: body} = node) do
    case go_wasmexports(body) do
      [] ->
        {:error, :no_exported_fns}

      exports ->
        caps = node |> Nexus.Audit.granted() |> Enum.filter(&Nexus.Dock.host_fn_wit/1)
        src_body = go_hostcall_prelude(caps) <> "\n" <> body
        src = Path.join(System.tmp_dir!(), "nxc_go_#{System.unique_integer([:positive])}.go")
        File.write!(src, src_body)

        with {:ok, core} <- Nexus.Compilers.Go.compile_to_wasm(src) do
          # Go string-return marker (packed-i64 export) is a follow-up; none for now → [].
          {:ok, core, exports, []}
        end
    end
  end

  @doc """
  ROUTE (a), Zig: compile a `zig` unit (zig → C → CORE wasm) and run it on `TinyLasers.Wasm`, no
  componentize/wasmex. Zig units are import-free today (no host caps), so this is a straight core compile;
  host_call wrappers + §5b string-return for zig are follow-ups. `{:ok, core_path, exports, str_exports}`.
  """
  def zig_unit_core(%{body: body}) do
    case zig_sigs(body) do
      [] ->
        {:error, :no_exported_fns}

      exports ->
        fn_exports = Enum.map(exports, &elem(&1, 0))
        src = Path.join(System.tmp_dir!(), "nxc_zigcore_#{System.unique_integer([:positive])}.zig")
        File.write!(src, body)

        with {:ok, core} <- Nexus.Compilers.Zig.compile_to_wasm(src, exports: fn_exports) do
          {:ok, core, fn_exports, []}
        end
    end
  end

  defp go_wasmexports(body) do
    ~r/\/\/go:wasmexport\s+(\w+)/ |> Regex.scan(body) |> Enum.map(fn [_, n] -> n end) |> Enum.uniq()
  end

  # Go route (a) prelude: the §7 host_call import (tinygo directive) + a shared result buffer + a typed
  # wrapper per cap (the `hello_bridge.go` shape), then the author's body + `func main() {}` (reactor).
  defp go_hostcall_prelude(caps) do
    ~S"""
    package main

    import "unsafe"

    //go:wasmimport env host_call
    func hostCall(np unsafe.Pointer, nl uint32, ap unsafe.Pointer, al uint32, op unsafe.Pointer, oc uint32) uint32

    var __hcOut [65536]byte

    func __hc(name string, args []byte) uint32 {
    	n := []byte(name)
    	return hostCall(unsafe.Pointer(&n[0]), uint32(len(n)), unsafe.Pointer(&args[0]), uint32(len(args)), unsafe.Pointer(&__hcOut[0]), uint32(len(__hcOut)))
    }

    func __jarg(parts ...string) []byte {
    	a := make([]byte, 0, 64)
    	a = append(a, '[')
    	for i, p := range parts {
    		if i > 0 {
    			a = append(a, ',')
    		}
    		a = append(a, '"')
    		for j := 0; j < len(p); j++ {
    			c := p[j]
    			if c == '"' || c == '\\' {
    				a = append(a, '\\')
    			}
    			a = append(a, c)
    		}
    		a = append(a, '"')
    	}
    	a = append(a, ']')
    	return a
    }
    """ <> "\n" <> Enum.map_join(caps, "\n", &go_hostcall_wrapper/1) <> "\nfunc main() {}\n"
  end

  # One typed Go wrapper per cap. String-param caps → string/void return; zero-arg → number return.
  defp go_hostcall_wrapper(cap) do
    {params, ret} = wit_parts(Nexus.Dock.host_fn_wit(cap))
    op = "dock_" <> to_string(cap)
    all_string? = params != [] and Enum.all?(params, fn {_, t} -> t == "string" end)

    cond do
      all_string? and ret == "string" ->
        args = 0..(length(params) - 1) |> Enum.map_join(", ", &"a#{&1}")
        sig = 0..(length(params) - 1) |> Enum.map_join(", ", &"a#{&1} string")

        "func #{cap}(#{sig}) string {\n" <>
          "\trl := __hc(#{inspect(op)}, __jarg(#{args}))\n" <>
          "\tif rl < 2 { return \"\" }\n\treturn string(__hcOut[1 : rl-1])\n}"

      all_string? ->
        sig = 0..(length(params) - 1) |> Enum.map_join(", ", &"a#{&1} string")
        args = 0..(length(params) - 1) |> Enum.map_join(", ", &"a#{&1}")
        "func #{cap}(#{sig}) {\n\t_ = __hc(#{inspect(op)}, __jarg(#{args}))\n}"

      params == [] and ret != nil and ret != "string" ->
        "func #{cap}() int64 {\n" <>
          "\trl := __hc(#{inspect(op)}, []byte(\"[]\"))\n\tvar v int64\n" <>
          "\tfor i := uint32(0); i < rl; i++ { if __hcOut[i] >= '0' && __hcOut[i] <= '9' { v = v*10 + int64(__hcOut[i]-'0') } }\n\treturn v\n}"

      true ->
        ""
    end
  end

  # One typed wrapper for a string-param cap (the common Dock shape: string args, string-or-void return).
  # Non-string params (u32 etc.) fall through to "" for now — the author calls host_call directly (v1).
  defp c_hostcall_wrapper(cap) do
    {params, ret} = wit_parts(Nexus.Dock.host_fn_wit(cap))

    if params != [] and Enum.all?(params, fn {_, t} -> t == "string" end) do
      op = "dock_" <> to_string(cap)
      n = length(params)
      cparams = 0..(n - 1) |> Enum.map_join(", ", fn i -> "const char* __p#{i}, int __n#{i}" end)

      fields =
        0..(n - 1)
        |> Enum.map_join("\n", fn i ->
          comma = if i > 0, do: "  __a[__j++] = ',';\n", else: ""

          comma <>
            (~S"""
               __a[__j++] = '"';
               for (int __i = 0; __i < __nI; __i++) { char __c = __pI[__i]; if (__c == '"' || __c == '\\') __a[__j++] = '\\'; __a[__j++] = __c; }
               __a[__j++] = '"';
             """
             |> String.replace("__nI", "__n#{i}")
             |> String.replace("__pI", "__p#{i}"))
        end)

      {cret, retcode} =
        if ret == "string",
          do: {"nx_str", "  if (__rl < 2) return (nx_str){__hc_out, 0};\n  return (nx_str){__hc_out + 1, __rl - 2};"},
          else: {"void", "  (void)__rl;"}

      """
      static #{cret} #{cap}(#{cparams}) {
        char __a[16384]; int __j = 0; __a[__j++] = '[';
      #{fields}  __a[__j++] = ']';
        int __rl = host_call("#{op}", #{byte_size(op)}, __a, __j, __hc_out, sizeof(__hc_out));
      #{retcode}
      }
      """
    else
      ""
    end
  end

  # The injected C prelude: `nx_str` type, extern decls for granted caps, and clean wrappers for
  # single-string-param string-returning caps (`<cap>_s(const char* p, int n) -> nx_str`).
  defp c_prelude(inject, _caps) do
    # Only grant-INJECTED caps get the extern + wrapper. Author-declared externs keep their own
    # (declaring + wrapping the same fn would double-declare `load` across the prelude/body split).
    str_caps = Enum.filter(inject, fn c -> match?({[{_, "string"}], "string"}, wit_parts(Nexus.Dock.host_fn_wit(c))) end)
    nx = if str_caps == [], do: "", else: "typedef struct { const char* ptr; int len; } nx_str;\n"
    externs = Enum.map_join(inject, "\n", &c_cap_extern/1)
    wrappers = Enum.map_join(str_caps, "\n", &c_str_wrapper/1)
    [nx, externs, wrappers] |> Enum.reject(&(&1 == "")) |> Enum.join("\n") |> then(&if(&1 == "", do: "", else: &1 <> "\n"))
  end

  # WIT sig → `{[{name, type}], return_type | nil}`.
  defp wit_parts(sig) do
    params =
      case Regex.run(~r/func\(([^)]*)\)/, sig || "") do
        [_, p] -> p
        _ -> ""
      end
      |> String.split(",", trim: true)
      |> Enum.map(fn p ->
        case String.split(p, ":", parts: 2) do
          [n, t] -> {String.trim(n), String.trim(t)}
          [t] -> {"_", String.trim(t)}
        end
      end)

    ret = with [_, r] <- Regex.run(~r/->\s*(\w+)/, sig || ""), do: r, else: (_ -> nil)
    {params, ret}
  end

  @wit_c %{"s8" => "signed char", "s16" => "short", "s32" => "int", "s64" => "long",
           "u8" => "unsigned char", "u16" => "unsigned short", "u32" => "unsigned int", "u64" => "unsigned long",
           "f32" => "float", "f64" => "double", "bool" => "int"}

  defp c_cap_extern(cap) do
    {params, ret} = wit_parts(Nexus.Dock.host_fn_wit(cap))
    cparams = Enum.flat_map(params, fn {_, "string"} -> ["const char*", "int"]; {_, t} -> [Map.get(@wit_c, t, "int")] end)
    cparams = cparams ++ if(ret == "string", do: ["void*"], else: [])
    cret = case ret do "string" -> "void"; nil -> "void"; t -> Map.get(@wit_c, t, "int") end
    "extern #{cret} #{cap}(#{if(cparams == [], do: "void", else: Enum.join(cparams, ", "))});"
  end

  defp c_str_wrapper(cap) do
    "static nx_str #{cap}_s(const char* __p, int __n) { unsigned int __r[2]; #{cap}(__p, __n, __r); return (nx_str){(const char*)(unsigned long)__r[0], (int)__r[1]}; }"
  end

  defp c_import_names(body) do
    ~r/\bextern\s+[a-z]\w*\s+([a-z_]\w*)\s*\(/
    |> Regex.scan(body)
    |> Enum.map(fn [_, n] -> n end)
    |> Enum.uniq()
  end

  # A `zig` unit: derive the WIT world from `export fn` signatures, compile (zig→C→wasm reactor).
  defp zig_unit(%{name: name, body: body}) do
    case zig_sigs(body) do
      [] ->
        {:error, :no_exported_fns}

      exports ->
        wname = wit_ident(name)
        elines = Enum.map(exports, fn {f, ps, r} -> {wit_ident(f), "func(#{ps})#{r}"} end)
        world = Nexus.Wit.world_from_sigs(name, [], elines)
        src = Path.join(System.tmp_dir!(), "nxc_#{System.unique_integer([:positive])}.zig")
        File.write!(src, body)

        with {:ok, core} <- Nexus.Compilers.Zig.compile_to_wasm(src, exports: Enum.map(exports, &elem(&1, 0))) do
          Nexus.Wit.componentize(core, world, wname) |> mark_washy(world)
        end
    end
  end

  # A `swift` unit: derive the WIT world from `@_expose(wasm)`d `public func` signatures, compile via
  # the official Swift wasm SDK (swiftc → wasm core), then componentize. swift → wasm reactor.
  defp swift_unit(%{name: name, body: body}) do
    case swift_sigs(body) do
      [] ->
        {:error, :no_exported_fns}

      exports ->
        wname = wit_ident(name)
        elines = Enum.map(exports, fn {f, ps, r} -> {wit_ident(f), "func(#{ps})#{r}"} end)
        world = Nexus.Wit.world_from_sigs(name, [], elines)
        src = Path.join(System.tmp_dir!(), "nxc_#{System.unique_integer([:positive])}.swift")
        File.write!(src, body)

        with {:ok, core} <- Nexus.Compilers.Swift.compile_to_wasm(src, exports: Enum.map(exports, &elem(&1, 0))) do
          Nexus.Wit.componentize(core, world, wname) |> mark_washy(world)
        end
    end
  end

  # ── the JS family — QuickJS-ng command modules (stdin→stdout), the toolkit shape ──────────────
  # `js`/`ts`/`svelte`/`solid`/`python` are INTERPRETER lanes: the source is embedded into a wasm
  # command module that evals it. ts/svelte/solid transpile to JS in-sandbox, then reuse the JS lane.
  # `harness_dock.o` (caps) is selected when the unit grants capabilities.

  defp js_unit(%{body: body} = node), do: Nexus.Compilers.Js.js_compile_to_wasm(body, dock: granted?(node))

  defp ts_unit(%{body: body} = node) do
    with {:ok, js} <- Nexus.Compilers.Js.transpile(:ts, body) do
      Nexus.Compilers.Js.js_compile_to_wasm(js, dock: granted?(node))
    end
  end

  # python's artifact = the interpreter + the unit's source (dedented; `.work` block bodies carry the
  # block indentation and python is indent-sensitive). The run path mounts the source + runs the interp.
  defp python_unit(%{body: body}) do
    case Nexus.Compilers.Python.python_compile_to_wasm(body) do
      {:ok, interp} -> {:ok, {:interp, interp, dedent(body)}}
      err -> err
    end
  end

  # Strip the common leading-whitespace prefix from every non-blank line (a `.work` block body is
  # uniformly indented under its `do`). Indent-sensitive languages (python) need this before running.
  defp dedent(body) do
    lines = String.split(body, "\n")

    min_indent =
      lines
      |> Enum.reject(&(String.trim(&1) == ""))
      |> Enum.map(&(String.length(&1) - String.length(String.trim_leading(&1))))
      |> Enum.min(fn -> 0 end)

    Enum.map_join(lines, "\n", fn line ->
      if String.length(line) >= min_indent, do: String.slice(line, min_indent..-1//1), else: line
    end)
  end

  # svelte/solid → transpile to browser JS, emitted as a client island. Errors propagate as
  # {:error, _} (loud), never a silent empty island.
  defp svelte_client(%{body: body}) do
    case Nexus.Compilers.Js.transpile(:svelte, body) do
      {:ok, js} -> {:client, js}
      err -> err
    end
  end

  defp solid_client(%{body: body}) do
    case Nexus.Compilers.Js.transpile(:solid, body) do
      {:ok, js} -> {:client, js}
      err -> err
    end
  end

  defp granted?(node), do: Nexus.Audit.granted(node) != []

  @swift_wit %{
    "Int8" => "s8", "Int16" => "s16", "Int32" => "s32", "Int64" => "s64", "Int" => "s32",
    "UInt8" => "u8", "UInt16" => "u16", "UInt32" => "u32", "UInt64" => "u64", "UInt" => "u32",
    "Float" => "f32", "Double" => "f64", "Bool" => "bool"
  }
  # `@_expose(wasm[, "name"]) public func f(_ x: Int32, y: Double) -> Int32 {` — the wasm-exposed entry.
  defp swift_sigs(body) do
    ~r/@_expose\([^)]*\)\s*public\s+func\s+([a-zA-Z_]\w*)\s*\(([^)]*)\)\s*(?:->\s*([A-Za-z0-9_]+))?\s*\{/
    |> Regex.scan(body)
    |> Enum.map(fn
      [_, f, params, ret] -> {f, swift_params(params), swift_ret(ret)}
      [_, f, params] -> {f, swift_params(params), ""}
    end)
    |> Enum.uniq()
  end

  defp swift_params(p) when p in ["", "_", "void"], do: ""

  defp swift_params(params) do
    params
    |> String.split(",", trim: true)
    |> Enum.map_join(", ", fn part ->
      # Swift params are `[label] name: Type` (label may be `_`); take the binding name + type.
      case String.split(part, ":", parts: 2) do
        [decl, t] ->
          nm = decl |> String.trim() |> String.split(~r/\s+/) |> List.last()
          "#{wit_ident(nm)}: #{Map.get(@swift_wit, String.trim(t), "s32")}"

        [t] ->
          Map.get(@swift_wit, String.trim(t), "s32")
      end
    end)
  end

  defp swift_ret(r) when r in [nil, ""], do: ""
  defp swift_ret(t), do: " -> #{Map.get(@swift_wit, t, "s32")}"

  @zig_wit %{
    "i8" => "s8", "i16" => "s16", "i32" => "s32", "i64" => "s64",
    "u8" => "u8", "u16" => "u16", "u32" => "u32", "u64" => "u64",
    "f32" => "f32", "f64" => "f64", "bool" => "bool"
  }
  defp zig_sigs(body) do
    ~r/\bexport\s+fn\s+([a-z_]\w*)\s*\(([^)]*)\)\s*([A-Za-z0-9_]+)\s*\{/
    |> Regex.scan(body)
    |> Enum.map(fn [_, f, params, ret] -> {f, zig_params(params), " -> #{Map.get(@zig_wit, ret, "s32")}"} end)
    |> Enum.uniq()
  end

  defp zig_params(""), do: ""
  defp zig_params("void"), do: ""

  defp zig_params(params) do
    params
    |> String.split(",", trim: true)
    |> Enum.map_join(", ", fn p ->
      case String.split(p, ":", parts: 2) do
        [n, t] -> "#{wit_ident(String.trim(n))}: #{Map.get(@zig_wit, String.trim(t), "s32")}"
        [t] -> Map.get(@zig_wit, String.trim(t), "s32")
      end
    end)
  end

  # C signatures: `<ret> name(params) {`. Maps C scalar types → WIT.
  @c_wit %{
    "int" => "s32", "long" => "s64", "char" => "s8", "short" => "s16",
    "unsigned" => "u32", "float" => "f32", "double" => "f64", "bool" => "bool"
  }
  defp c_sigs(body) do
    ~r/\b([a-z]\w*)\s+([a-z_]\w*)\s*\(([^)]*)\)\s*\{/
    |> Regex.scan(body)
    |> Enum.map(fn [_, ret, f, params] -> {f, c_params(params), c_ret(ret)} end)
    |> Enum.uniq()
  end

  defp c_params(p) when p in ["", "void"], do: ""

  defp c_params(params) do
    params
    |> String.split(",", trim: true)
    |> Enum.map_join(", ", fn part ->
      ws = part |> String.trim() |> String.split(~r/\s+/)
      {nm, ty} = {List.last(ws), ws |> Enum.drop(-1) |> List.last()}
      "#{wit_ident(nm)}: #{Map.get(@c_wit, ty, "s32")}"
    end)
  end

  defp c_ret("void"), do: ""
  defp c_ret(t), do: " -> #{Map.get(@c_wit, t, "s32")}"

  # A unit declares crate deps with a `// deps: libm, regex` header line; the lane fetches +
  # resolves them from crates.io (version-floors handle ceiling-exceeding releases).
  defp crate_deps(body) do
    case Regex.run(~r/\/\/\s*deps:\s*(.+)/, body) do
      [_, list] -> list |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      _ -> []
    end
  end

  @doc """
  Bring up a whole `.work` folder. The fast tiers come up eagerly — `server`/type units →
  native BEAM modules, `resource` units → compiled struct modules (rows live in `Nexus.Store`);
  the `wasm` units (rust/…) are
  enumerated as compile-on-demand (each is a real, slow toolchain build via `unit/1`). Returns
  `%{beam, resources, wasm_units}`.
  """
  @doc """
  COMPILE-CHECK a workbook tree without mounting it — the deploy gate (`work check`/the nexus
  pre-receive hook run this before a push goes live). Compiles every IN-PROCESS unit kind the nexus
  brings up — `server`/`defmodule` (beam, via the dependency-fixpoint compile), plus `resource`,
  `hook`, `flow`, `worker`, `agent`, `check`, `toolkit` — and AGGREGATES every failure (these are
  individually `rescue`d to warnings in `workbook/1`; here they are errors). Returns:

      %{ok?: boolean,
        errors:  [%{kind, name, reason}],   # anything that would fail bringup → reject the deploy
        skipped: [%{kind, name, reason}]}    # wasm/client lanes NOT gated here (no in-image toolchain
                                             # or render-passthrough) — REPORTED, never silently passed

  Defines/registers modules as a side effect (it really compiles), so run it in an ISOLATED node
  (`bin/nexus eval`), never against the live serving node — `eval` is a throwaway process.
  """
  @doc """
  CLI/hook entrypoint for the compile gate — runs `check/1`, prints a human report, and `System.halt(1)`
  on failure so a caller (`bin/nexus eval Nexus.Compile.gate(dir)` in the pre-receive hook) sees a
  non-zero exit and REJECTS the push. On success returns `:ok`.
  """
  @doc """
  Env-driven gate entrypoint — reads the tree path from `WB_GATE_TREE` instead of having the caller
  splice it into an `eval` source string. The pre-receive hook sets the env var and calls a fixed,
  data-free eval, so push-controlled bytes (`$tmp`, refs) never enter an Elixir source string (red-team
  wb-livx). Fails closed: a missing/empty `WB_GATE_TREE` rejects the push.
  """
  def gate_from_env do
    case System.get_env("WB_GATE_TREE") do
      dir when is_binary(dir) and dir != "" -> gate(dir)
      _ -> IO.puts("✗ compile gate: WB_GATE_TREE unset"); System.halt(1)
    end
  end

  def gate(dir) do
    r = check(dir)
    for s <- r.skipped, do: IO.puts("· not gated: #{s.kind} :#{s.name} — #{s.reason}")

    if r.ok? do
      IO.puts("✓ compile check passed")
      :ok
    else
      IO.puts("✗ compile check FAILED — push rejected:")
      for e <- r.errors, do: IO.puts("  ✗ #{e.kind} :#{e.name} — #{e.reason}")
      System.halt(1)
    end
  end

  def check(root) do
    nodes =
      (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
      |> Enum.uniq()
      |> Enum.flat_map(fn p -> File.read!(p) |> Nexus.Literate.parse() |> Enum.map(&Map.put(&1, :src, p)) end)
      |> Enum.filter(&(&1.type == :code))

    # Beam (server + every nested defmodule) compiles as ONE fixpoint so cross-unit struct deps resolve
    # in any order — use the workbook compiler and read its `failed`, rather than compiling each in isolation.
    beam_errors =
      case (try do Nexus.Unit.compile_workbook(root) rescue e -> {:error, Exception.message(e)} end) do
        %{failed: failed} -> Enum.map(failed, fn {name, r} -> %{kind: "server", name: name, reason: check_reason(r)} end)
        {:error, msg} -> [%{kind: "server", name: nil, reason: msg}]
        _ -> []
      end

    # SYNTAX errors: the literate parser is lenient — a unit whose body fails to parse gets `ast: nil`
    # and is silently dropped by the compilers. For an Elixir-lane kind, nil ast == a syntax error, so
    # flag it explicitly (these never reach beam_errors/check_unit). client/wasm bodies are non-Elixir,
    # so their nil ast is normal and excluded here.
    elixir_kinds = ~w(server resource hook flow worker agent)

    syntax_errors =
      for n <- nodes, n.kind in elixir_kinds, n.ast == nil,
        do: %{kind: n.kind, name: n.name, reason: "syntax error — unit body did not parse as Elixir"}

    # The other in-process kinds (with a parsed body): compile each individually, capturing a raise OR
    # an {:error, _}. nil-ast ones are already covered by syntax_errors above (skip to avoid double-count).
    gateable = ~w(resource hook flow worker agent check toolkit)

    other_errors =
      for n <- nodes, n.kind in gateable, n.ast != nil, err = check_unit(n), err != nil, do: err

    # wasm compile lanes (slow toolchain builds) + client/sandbox passthrough are NOT gated in-process:
    # report them honestly so a pass never *looks* like full coverage it didn't do.
    skipped =
      for n <- nodes, n.kind in (@wasm_kinds ++ ~w(client sandbox)) do
        %{kind: n.kind, name: n.name,
          reason: "wasm/client lane — checked at build/browser, not by this gate (no in-image toolchain or render-passthrough)"}
      end

    errors = beam_errors ++ syntax_errors ++ other_errors
    %{ok?: errors == [], errors: errors, skipped: skipped}
  end

  # Compile one non-beam in-process unit; nil if it's fine, %{kind,name,reason} if it fails (raise or
  # {:error, _}). Wrapped so one bad unit can't crash the whole check.
  defp check_unit(node) do
    case (try do unit(node) rescue e -> {:__raised__, Exception.message(e)} end) do
      {:__raised__, msg} -> %{kind: node.kind, name: node.name, reason: msg}
      {_lane, {:error, reason}} -> %{kind: node.kind, name: node.name, reason: check_reason(reason)}
      _ -> nil
    end
  end

  defp check_reason(r) when is_binary(r), do: r
  defp check_reason(r), do: inspect(r)

  def workbook(root) do
    units =
      (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
      |> Enum.uniq()
      |> Enum.flat_map(fn f ->
        # Stamp each unit with its source file so bringup can resolve the `index.work` ceiling
        # governing it (Autopoiesis v2 — ceiling-in-index).
        f |> File.read!() |> Nexus.Literate.parse() |> Enum.filter(&(&1.type == :code)) |> Enum.map(&Map.put(&1, :src, f))
      end)

    # Trust gate (wb-rh95): drop native-BEAM units (worker/hook/def/test/auth) authored in an UNTRUSTED
    # subtree before they're compiled/armed — native Elixir can't be sandboxed in-process. (server units
    # are gated equivalently in Nexus.Unit.compile_workbook / try_beam.) Trusted (default) = unchanged.
    {units, refused} =
      Nexus.Trust.partition(Enum.map(units, &{&1, Path.relative_to(&1.src, root)}))

    for {_u, path, {:untrusted_native_kind, kind, _}} <- refused do
      require Logger
      Logger.warning("[trust] refused native `#{kind}` unit in untrusted workspace #{path} (wb-rh95)")
    end

    by_kind = Enum.group_by(units, & &1.kind)

    resources =
      for u <- Map.get(by_kind, "resource", []) do
        {u.name, try_materialize(u)}
      end

    # Register declared hooks (the reactive layer) so the event bus can dispatch to them at runtime.
    for u <- Map.get(by_kind, "hook", []) do
      try do
        Nexus.Hook.compile(u)
      rescue
        e -> require Logger; Logger.warning("[compile] hook #{u.name} failed: #{Exception.message(e)}")
      end
    end

    # Register declared flows (the composing half) so hooks/code can run them by name.
    for u <- Map.get(by_kind, "flow", []) do
      try do
        Nexus.Flow.compile(u)
      rescue
        e -> require Logger; Logger.warning("[compile] flow #{u.name} failed: #{Exception.message(e)}")
      end
    end

    # Register declared agents so they can be run BY NAME (server code, effects, flow steps). Resolve
    # each agent's governing capability CEILING now (root + tree known) and stamp it onto the node, so
    # `run_unit` clamps `declared ∩ ceiling` on every run. Re-resolves on recompile/hot-reload — exactly
    # when an `index.work` ceiling could have changed.
    for u <- Map.get(by_kind, "agent", []) do
      dir = case Map.get(u, :src) do
        p when is_binary(p) -> Path.dirname(p)
        _ -> root
      end

      Nexus.Agent.register(Map.put(u, :ceiling, Nexus.Index.effective_ceiling(root, dir)))
    end

    # Compile declared workers (long-lived supervised processes) into modules + registered specs.
    # This does NOT start them — the serving bringup calls Nexus.Worker.start_all/0; a pure compile
    # or `mix test` only registers, so it never spawns background loops.
    for u <- Map.get(by_kind, "worker", []) do
      try do
        Nexus.Worker.compile(u)
      rescue
        e -> require Logger; Logger.warning("[compile] worker #{u.name} failed: #{Exception.message(e)}")
      end
    end

    wasm = Enum.flat_map(~w(rust c cpp zig swift), &Map.get(by_kind, &1, []))

    %{
      beam: try_beam(root),
      resources: resources,
      wasm_units: for(u <- wasm, do: u.name)
    }
  end

  @doc """
  Compile the workbook's wasm units and read each component's REAL WIT back into a
  reality overlay (§10, artifact facet): for every compilable wasm unit,
  `facets.artifact` = the built component's actual imports/exports + `drift` against
  the unit's declared interface (§2). Join with `Nexus.Graph.with_overlay/2` to
  populate `facets.artifact` on the graph — declared intent checked against the
  shipped binary. `opts[:only]` limits to named units (faster, targeted builds).
  """
  def artifact_overlay(root, opts \\ []) do
    g = Nexus.Graph.build_dir(root)
    only = opts[:only]

    (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
    |> Enum.uniq()
    |> Enum.flat_map(fn f -> f |> File.read!() |> Nexus.Literate.parse() |> Enum.filter(&(&1.type == :code)) end)
    |> Enum.filter(&(&1.kind in ~w(rust c cpp zig swift) and (only == nil or &1.name in only)))
    |> Enum.reduce(Nexus.Overlay.new(), fn node, ov ->
      with {:wasm, {:ok, comp}} <- unit(node),
           {:ok, facet} <- Nexus.Artifact.facet(comp) do
        declared = get_in(g.nodes, [node.name, :facets, :interface])
        drift = if declared, do: Nexus.Artifact.diff(declared, facet.wit), else: nil
        Nexus.Overlay.put_artifact(ov, node.name, Map.put(facet, :drift, drift))
      else
        _ -> ov
      end
    end)
  end

  defp try_beam(root) do
    Nexus.Unit.compile_workbook(root)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp try_materialize(u) do
    {:ok, Nexus.Resource.compile(u)}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @adapter "build/tools/wasi_snapshot_preview1.command.wasm"

  @doc """
  The wasm lane, proven end-to-end: Rust `source` exporting `fns` → a typed wasm component
  bound to `wit_text`'s `world`. Three steps, no command machinery:

    1. append a keep-alive `main` referencing each fn (mrustc transpiles whole-program FROM main,
       so an unreferenced `pub fn` is never emitted) — `wasm-ld --export` then surfaces them;
    2. compile to a core module via the moat (`Nexus.Compilers.Rust`);
    3. componentize against the GENERATED WIT world (`wasm-tools embed` + `new`).

  Returns `{:ok, component_path}` — runnable on `Nexus.Sandbox`.
  """
  # libstd internals that, when a rust unit pulls libstd (String/alloc), are left as `env` imports
  # by --allow-undefined and would otherwise pollute the world's import space. Defining them as
  # stubs keeps ONLY the real host caps imported, so string caps lift cleanly (docs/STRING-CAP-ABI.md).
  @rust_stubs """
  #[no_mangle] pub extern "C" fn abort() { loop {} }
  #[no_mangle] pub extern "C" fn _Unwind_Resume(_p: *mut u8) { loop {} }
  #[no_mangle] pub extern "C" fn __rust_alloc_error_handler(_a: usize, _b: usize) { loop {} }
  """

  def to_component(source, fns, wit_text, world, import_names \\ [], deps \\ []) when is_list(fns) do
    dir = Path.join(System.tmp_dir!(), "nxc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    src = Path.join(dir, "u.rs")
    body = if import_names == [], do: source, else: source <> "\n" <> @rust_stubs
    File.write!(src, body <> "\n" <> keepalive_main(fns))

    with {:ok, core, _} <-
           Nexus.Compilers.Rust.rust_compile_to_wasm(src, exports: fns, allow_undefined: true, deps: deps) do
      # mrustc emits host imports as `env::<fn>`; the component model wants them at `$root`. Rewrite
      # ONLY the declared cap imports (leaving any libstd env refs alone — the stubs define those).
      core = if import_names == [], do: core, else: rewrite_imports(core, dir, import_names)
      componentize(core, wit_text, world, dir)
    end
  end

  # Selectively rewrite `env::<name>` → `$root::<name>` for each declared host import (a wat
  # round-trip). Used by the rust and C lanes; only the named caps move, nothing else.
  defp rewrite_imports(core, dir, names) do
    {wat, 0} = System.cmd("wasm-tools", ["print", core])
    rewritten = Enum.reduce(names, wat, fn n, acc ->
      String.replace(acc, ~s/(import "env" "#{n}"/, ~s/(import "$root" "#{n}"/)
    end)
    out = Path.join(dir, "rooted.wasm")
    watp = Path.join(dir, "rooted.wat")
    File.write!(watp, rewritten)
    {_, 0} = System.cmd("wasm-tools", ["parse", watp, "-o", out])
    out
  end

  # A main that black-box-references each export's address so mrustc emits the symbol (it
  # transpiles whole-program from main; a plain `as *const ()` gets constant-folded away, but
  # black_box defeats the fold). No call → signature-agnostic. `--export` then surfaces it.
  defp keepalive_main(fns) do
    refs = Enum.map_join(fns, " ", &"core::hint::black_box(#{&1} as usize);")
    "fn main() { #{refs} }\n"
  end

  defp componentize(core, wit_text, world, dir) do
    wit = Path.join(dir, "w.wit")
    embed = Path.join(dir, "e.wasm")
    comp = Path.join(dir, "c.component.wasm")
    adapter = Path.expand(@adapter, File.cwd!())
    File.write!(wit, wit_text)

    with {_, 0} <- System.cmd("wasm-tools", ["component", "embed", wit, core, "--world", world, "-o", embed]),
         {_, 0} <- System.cmd("wasm-tools", ["component", "new", embed, "--adapt", "wasi_snapshot_preview1=#{adapter}", "-o", comp]) do
      {:ok, comp}
    else
      {out, code} -> {:error, {:componentize_failed, code, out}}
    end
  end

  # Rust scalar → WIT type. (Records/strings come with the typed-extractor; scalars cover the
  # numeric/bool surface the component ABI lifts directly.)
  @rust_wit %{
    "i8" => "s8", "i16" => "s16", "i32" => "s32", "i64" => "s64",
    "u8" => "u8", "u16" => "u16", "u32" => "u32", "u64" => "u64",
    "f32" => "f32", "f64" => "f64", "bool" => "bool"
  }

  # `pub fn name(params) -> ret { … }` (body) = export;  `fn name(params) -> ret;` (decl, no
  # body, inside an `extern "C"` block) = a host import the Dock supplies.
  @export_re ~r/pub\s+(?:extern\s+"C"\s+)?fn\s+([a-z_]\w*)\s*\(([^)]*)\)\s*(?:->\s*([A-Za-z0-9_]+))?\s*\{/
  @import_re ~r/\bfn\s+([a-z_]\w*)\s*\(([^)]*)\)\s*(?:->\s*([A-Za-z0-9_]+))?\s*;/

  @doc """
  Derive a typed WIT world from a `rust` unit — `pub fn` bodies become **exports**, `extern "C"`
  declarations become **imports** (host capabilities). No hand-written WIT. Returns
  `%{world, name, exports, imports}` where exports/imports are `{name, params, ret}` tuples.
  """
  def rust_world(%{name: name, body: body}) do
    exports = sigs(@export_re, body)
    imports = sigs(@import_re, body)
    wname = wit_ident(name)

    ilines = Enum.map(imports, fn {f, ps, r} -> {wit_ident(f), "func(#{ps})#{r}"} end)
    elines = Enum.map(exports, fn {f, ps, r} -> {wit_ident(f), "func(#{ps})#{r}"} end)
    world = Nexus.Wit.world_from_sigs(name, ilines, elines)
    %{world: world, name: wname, exports: exports, imports: imports}
  end

  defp sigs(re, body) do
    Regex.scan(re, body)
    |> Enum.map(fn [_, f, params | rest] -> {f, parse_params(params), wit_ret(List.first(rest))} end)
    |> Enum.uniq()
  end

  defp parse_params(""), do: ""

  defp parse_params(params) do
    params
    |> String.split(",", trim: true)
    |> Enum.map_join(", ", fn p ->
      case String.split(p, ":", parts: 2) do
        [n, t] -> "#{wit_ident(String.trim(n))}: #{wit_type(String.trim(t))}"
        [t] -> wit_type(String.trim(t))
      end
    end)
  end

  defp wit_ret(r) when r in [nil, ""], do: ""
  defp wit_ret(t), do: " -> #{wit_type(t)}"
  defp wit_type(t), do: Map.get(@rust_wit, t, "s32")
  defp wit_ident(s), do: Nexus.Uid.wit(s)
end
