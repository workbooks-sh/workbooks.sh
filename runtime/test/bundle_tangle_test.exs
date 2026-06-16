defmodule Workbooks.BundleTangleTest do
  @moduledoc """
  Pins the TANGLE/COMPILE wiring into the bundle lifecycle (docs/WORKBOOK-BUNDLE.md
  "the workbook compiler"): org source-of-truth → tangled native source
  (`Bundle.tangle_files` REUSING `OQL.tangle_plan`) → compile-shape
  (`Bundle.compile_tree` REUSING `Workbooks.Build`/PackageManager) → packed +
  embedded `.html` carrying org + native + (when built) `.wasm`.

  Hermetic: the org→tangle leg runs the REAL embedded OQL kernel (no network,
  no LLM). The heavy compile leg is asserted at the WIRING level — `compile_tree`
  detection + `build: false` skip — so the default run needs no wasm toolchain.
  A real end-to-end compile lives behind the `:build` tag (excluded by default;
  run with `mix test --include build` in a provisioned env).
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Bundle, CLI}

  setup_all do
    # The OQL kernel is a named GenServer over the embedded oql.wasm — hermetic
    # (pure compute, no host/network). Tolerate it already being up.
    case Workbooks.OQL.start_link(nil) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  setup do
    base = Path.join(System.tmp_dir!(), "wb_bundle_tangle_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  # A literate Workbook: one workflow with one Rust :component: code block. This
  # is the source-of-truth; the .rs is DERIVED by tangle, never authored directly.
  @org """
  * Adder :workflow:
  A trivial compute workflow.

  ** add :component:
  :PROPERTIES:
  :END:
  #+begin_src rust :out sum :dir crates/add
  #[no_mangle]
  pub extern "C" fn add(a: i32, b: i32) -> i32 { a + b }
  #+end_src
  """

  test "tangle_files materializes org :component: blocks → native source (org→native)" do
    parts = Bundle.tangle_files(%{"source.org" => @org})

    # The Rust component tangles to <dir>/<name>.rs with its source-block body.
    assert Map.has_key?(parts, "crates/add/add.rs"),
           "expected tangled crates/add/add.rs, got: #{inspect(Map.keys(parts))}"

    rs = parts["crates/add/add.rs"]
    assert rs =~ "pub extern \"C\" fn add"
    assert rs =~ "a + b"

    # The org source-of-truth survives — the bundle stays re-editable, re-tangles
    # on each rebuild (the "edit source not compiled wasm" invariant).
    assert parts["source.org"] == @org
  end

  test "tangle is idempotent + the org wins over a stale tangled file (re-tangle)" do
    base = %{"source.org" => @org, "crates/add/add.rs" => "STALE — should be overwritten\n"}

    once = Bundle.tangle_files(base)
    twice = Bundle.tangle_files(once)

    assert once == twice, "tangle_files must be idempotent"
    refute once["crates/add/add.rs"] =~ "STALE"
    assert once["crates/add/add.rs"] =~ "pub extern"
  end

  test "a non-literate tree (no org) passes through tangle unchanged" do
    parts = %{"index.html" => "<h1>hi</h1>", "data/x.bin" => <<1, 2, 3>>}
    assert Bundle.tangle_files(parts) == parts
  end

  test "compile_tree detects buildable native source but skips the heavy compile on build:false" do
    parts = Bundle.tangle_files(%{"source.org" => @org})

    # build: false → compile is skipped; the tangled native source still ships
    # (source-only / archive projection). Hermetic: no lane spin-up.
    source_only = Bundle.compile_tree(parts, build: false)
    assert source_only == parts
    assert Map.has_key?(source_only, "crates/add/add.rs")
    refute Enum.any?(Map.keys(source_only), &String.ends_with?(&1, ".wasm"))
  end

  test "compile_tree is a no-op for a tree with nothing to build" do
    parts = %{"index.html" => "<h1>hi</h1>", "source.org" => "* Doc\njust prose\n"}
    assert Bundle.compile_tree(parts, build: true) == parts
  end

  test "work bundle (--no-build) tangles org→native then packs + embeds; round-trips", %{base: base} do
    src = Path.join(base, "src")
    out = Path.join(base, "page.html")
    dst = Path.join(base, "dst")

    File.mkdir_p!(src)
    File.write!(Path.join(src, "source.org"), @org)

    # --no-build: the heavy compile is skipped, but the org STILL tangles to native
    # before pack — so the wiring (org→tangle→pack→embed) is exercised hermetically.
    msg = CLI.call(["bundle", src, out, "--no-build"], nil)
    assert msg =~ "bundled"
    assert File.exists?(out)

    # The embedded bundle carries the org source-of-truth AND the tangled native.
    blob = Bundle.extract(File.read!(out))
    assert is_binary(blob)
    parts = Bundle.unpack(blob)
    assert parts["source.org"] == @org
    assert Map.has_key?(parts, "crates/add/add.rs")
    assert parts["crates/add/add.rs"] =~ "pub extern"

    # unbundle reconstitutes both the org and the tangled native source on disk.
    CLI.call(["unbundle", out, dst], nil)
    assert File.read!(Path.join(dst, "source.org")) == @org
    assert File.read!(Path.join(dst, "crates/add/add.rs")) =~ "pub extern"
  end

  @tag :build
  test "work bundle (full compile) emits a runnable <name>.wasm part for the org component", %{base: base} do
    src = Path.join(base, "src")
    out = Path.join(base, "page.html")

    File.mkdir_p!(src)
    File.write!(Path.join(src, "source.org"), @org)

    CLI.call(["bundle", src, out], nil)

    parts = out |> File.read!() |> Bundle.extract() |> Bundle.unpack()
    # Source-of-truth org + tangled native + the compiled .wasm output all ship —
    # the install/3 shape (CommandRegistry registers `.wasm` parts).
    assert parts["source.org"] == @org
    assert Map.has_key?(parts, "crates/add/add.rs")

    wasm = Enum.filter(Map.keys(parts), &String.ends_with?(&1, ".wasm"))
    assert wasm != [], "expected a compiled .wasm part, got: #{inspect(Map.keys(parts))}"
  end
end
