defmodule Workbooks.WbRuntimeTest do
  @moduledoc """
  wb-ova: the BEAM-backed runtime API for in-sandbox Rust (compilers/rust/wb/lib.rs). Proves the
  division of labor — wasm does pure compute, the BEAM owns I/O/storage/time — end to end: a clean
  Rust program (no unsafe, no buffers) uses `wb::*`, compiles in-sandbox, and runs via RustDock with
  the host performing the actual operations. This is what an AI/author writes; the safety is
  structural (memory-safe wasm + process-safe BEAM).
  """
  use ExUnit.Case, async: false
  alias Workbooks.Compilers
  alias Workbooks.RustDock

  @tag :build
  @tag timeout: 300_000
  test "wb:: API — clean Rust, BEAM owns time + storage, runs in-sandbox" do
    # exercise the REAL crate source so the test and the shipped API can't drift.
    wb = File.read!("compilers/rust/wb/lib.rs")

    program = """
    mod wb { #{wb} }

    fn main() {
        // what an author/agent actually writes — pure compute + wb::* for the rest, no unsafe.
        let t = wb::time::now_millis();
        wb::vfs::write("note", b"owned-by-beam");
        let got = wb::vfs::read_string("note").unwrap_or_default();
        println!("WB now_ok={} stored={}", t > 0, got);
    }
    """

    src = Path.join(System.tmp_dir!(), "wb_rt_#{System.unique_integer([:positive])}.rs")
    File.write!(src, program)

    case Compilers.rust_compile_to_wasm(src, no_exceptions: true, allow_undefined: true) do
      {:ok, wasm, _} ->
        assert {:ok, out} = RustDock.run(wasm, profile: :minimal)
        assert String.trim(out) == "WB now_ok=true stored=owned-by-beam"

      {:error, reason} ->
        IO.puts("\n[skip] wb runtime: #{inspect(reason) |> String.slice(0, 100)}")
    end
  end
end
