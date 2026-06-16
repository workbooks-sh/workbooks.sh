defmodule Workbooks.BundleTangleTest do
  @moduledoc """
  Pins the TANGLE/COMPILE wiring into the bundle lifecycle (docs/WORKBOOK-BUNDLE.md
  "the workbook compiler"): workbook HTML source-of-truth → tangled native source
  (`Bundle.tangle_files` reading the plan via `Workbook.tangle_plan`, Floki) →
  compile-shape (`Bundle.compile_tree` REUSING `Workbooks.Build`/PackageManager) →
  packed + embedded `.html` carrying the HTML + native + (when built) `.wasm`.

  Hermetic: the HTML→tangle leg is pure Floki (no network, no LLM, no kernel). The
  heavy compile leg is asserted at the WIRING level — `compile_tree` detection +
  `build: false` skip — so the default run needs no wasm toolchain. A real
  end-to-end compile lives behind the `:build` tag (excluded by default; run with
  `mix test --include build` in a provisioned env).
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Bundle, CLI}

  setup do
    base = Path.join(System.tmp_dir!(), "wb_bundle_tangle_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  # A literate workbook: HTML with one work-flow holding one Rust work-component.
  # The HTML is the source-of-truth; the .rs is DERIVED by tangle, never authored
  # directly. The component's text body is its source; lang/out/dir are attributes.
  @work """
  <work-flow title="Adder">
    <work-component title="add" lang="rust" out="sum" dir="crates/add">
  #[no_mangle]
  pub extern "C" fn add(a: i32, b: i32) -> i32 { a + b }
    </work-component>
  </work-flow>
  """

  test "tangle_files materializes work-component bodies → native source (html→native)" do
    parts = Bundle.tangle_files(%{"index.html" => @work})

    # The Rust component tangles to <dir>/<name>.rs with its source-block body.
    assert Map.has_key?(parts, "crates/add/add.rs"),
           "expected tangled crates/add/add.rs, got: #{inspect(Map.keys(parts))}"

    rs = parts["crates/add/add.rs"]
    assert rs =~ "pub extern \"C\" fn add"
    assert rs =~ "a + b"

    # The HTML source-of-truth survives — the bundle stays re-editable, re-tangles
    # on each rebuild (the "edit source not compiled wasm" invariant).
    assert parts["index.html"] == @work
  end

  test "tangle is idempotent + the HTML wins over a stale tangled file (re-tangle)" do
    base = %{"index.html" => @work, "crates/add/add.rs" => "STALE — should be overwritten\n"}

    once = Bundle.tangle_files(base)
    twice = Bundle.tangle_files(once)

    assert once == twice, "tangle_files must be idempotent"
    refute once["crates/add/add.rs"] =~ "STALE"
    assert once["crates/add/add.rs"] =~ "pub extern"
  end

  test "a non-literate tree (no work-components) passes through tangle unchanged" do
    parts = %{"index.html" => "<h1>hi</h1>", "data/x.bin" => <<1, 2, 3>>}
    assert Bundle.tangle_files(parts) == parts
  end

  test "compile_tree detects buildable native source but skips the heavy compile on build:false" do
    parts = Bundle.tangle_files(%{"index.html" => @work})

    # build: false → compile is skipped; the tangled native source still ships
    # (source-only / archive projection). Hermetic: no lane spin-up.
    source_only = Bundle.compile_tree(parts, build: false)
    assert source_only == parts
    assert Map.has_key?(source_only, "crates/add/add.rs")
    refute Enum.any?(Map.keys(source_only), &String.ends_with?(&1, ".wasm"))
  end

  test "compile_tree is a no-op for a tree with nothing to build" do
    parts = %{"index.html" => "<work-doc title=\"Doc\">just prose</work-doc>"}
    assert Bundle.compile_tree(parts, build: true) == parts
  end

  test "work bundle (--no-build) tangles html→native then packs + embeds; round-trips", %{base: base} do
    src = Path.join(base, "src")
    out = Path.join(base, "page.html")
    dst = Path.join(base, "dst")

    File.mkdir_p!(src)
    File.write!(Path.join(src, "index.html"), @work)

    # --no-build: the heavy compile is skipped, but the HTML STILL tangles to native
    # before pack — so the wiring (html→tangle→pack→embed) is exercised hermetically.
    msg = CLI.call(["bundle", src, out, "--no-build"], nil)
    assert msg =~ "bundled"
    assert File.exists?(out)

    # The embedded bundle carries the HTML source-of-truth AND the tangled native.
    blob = Bundle.extract(File.read!(out))
    assert is_binary(blob)
    parts = Bundle.unpack(blob)
    assert parts["index.html"] == @work
    assert Map.has_key?(parts, "crates/add/add.rs")
    assert parts["crates/add/add.rs"] =~ "pub extern"

    # unbundle reconstitutes both the HTML and the tangled native source on disk.
    CLI.call(["unbundle", out, dst], nil)
    assert File.read!(Path.join(dst, "index.html")) == @work
    assert File.read!(Path.join(dst, "crates/add/add.rs")) =~ "pub extern"
  end

  @tag :build
  test "work bundle (full compile) emits a runnable <name>.wasm part for the component", %{base: base} do
    src = Path.join(base, "src")
    out = Path.join(base, "page.html")

    File.mkdir_p!(src)
    File.write!(Path.join(src, "index.html"), @work)

    CLI.call(["bundle", src, out], nil)

    parts = out |> File.read!() |> Bundle.extract() |> Bundle.unpack()
    # Source-of-truth HTML + tangled native + the compiled .wasm output all ship —
    # the install/3 shape (CommandRegistry registers `.wasm` parts).
    assert parts["index.html"] == @work
    assert Map.has_key?(parts, "crates/add/add.rs")

    wasm = Enum.filter(Map.keys(parts), &String.ends_with?(&1, ".wasm"))
    assert wasm != [], "expected a compiled .wasm part, got: #{inspect(Map.keys(parts))}"
  end
end
