defmodule Nexus.Compile do
  @moduledoc """
  Route a parsed unit to its artifact — the one place placement becomes execution:

      resource         → a typed struct           (the shape; persisted via `Nexus.Store`)
      record           → a value shape             (`Nexus.Resource`)
      server           → a native BEAM module      (`Nexus.Unit`)
      client / foreign → a wasm component          (the compilers → `Nexus.Sandbox`)

  Server units are native Elixir — no wasm. Everything else that isn't pure data compiles to
  wasm via OUR compilers (the moat) and runs on wasmex. The compilers are *reused* from the
  existing toolchain when we wire them in; this module just routes and orchestrates.
  """

  @wasm_kinds ~w(client sandbox rust zig c cpp python svelte solid js ts)

  @doc "Compile one parsed `:code` unit to its artifact, tagged by lane."
  def unit(%{type: :code, kind: kind} = node) do
    cond do
      kind == "resource" -> {:resource, Nexus.Resource.compile(node)}
      kind == "record" -> {:shape, Nexus.Resource.fields(node)}
      kind == "server" -> {:beam, Nexus.Unit.compile(node)}
      kind == "agent" -> {:agent, Nexus.Agent.def_from_unit(node)}
      kind == "check" -> {:check, Nexus.Checks.parse(node)}
      kind == "toolkit" -> {:toolkit, Nexus.Toolkit.build(node)}
      kind == "rust" -> {:wasm, rust_unit(node)}
      kind in ~w(c cpp) -> {:wasm, c_unit(node)}
      kind == "zig" -> {:wasm, zig_unit(node)}
      kind in @wasm_kinds -> {:wasm, {:todo, node.lang, node.name}}
      true -> {:skip, kind}
    end
  end

  def unit(_), do: {:skip, :not_a_unit}

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
          Nexus.Wit.componentize(core, world, wname)
        end
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
          Nexus.Wit.componentize(core, world, wname)
        end
    end
  end

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
  def workbook(root) do
    units =
      (Path.wildcard(Path.join(root, "*.work")) ++ Path.wildcard(Path.join(root, "**/*.work")))
      |> Enum.uniq()
      |> Enum.flat_map(fn f -> f |> File.read!() |> Nexus.Literate.parse() |> Enum.filter(&(&1.type == :code)) end)

    by_kind = Enum.group_by(units, & &1.kind)

    resources =
      for u <- Map.get(by_kind, "resource", []) do
        {u.name, try_materialize(u)}
      end

    wasm = Enum.flat_map(~w(rust c cpp zig), &Map.get(by_kind, &1, []))

    %{
      beam: try_beam(root),
      resources: resources,
      wasm_units: for(u <- wasm, do: u.name)
    }
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
