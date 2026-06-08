defmodule Workbooks.RustDockTest do
  @moduledoc """
  wb-1mv — BEAM Dock: compiled untrusted Rust calls host fns under Wasmex, getting runtime caps
  wasm alone lacks (clock/log/network/vfs), POLICY-GATED per profile. Each test compiles Rust with
  rust_compile_to_wasm(no_exceptions: true, allow_undefined: true) so externs survive as env.*
  imports + the wasm runs WITHOUT the exceptions proposal, then RustDock.run executes it with the
  profile's gated imports. @tag :netdeps where network is used. Proves the offload lever end-to-end.
  """
  use ExUnit.Case, async: false
  alias Workbooks.{Compilers, RustDock}

  defp build!(src) do
    p = Path.join(System.tmp_dir!(), "dock_#{System.unique_integer([:positive])}.rs")
    File.write!(p, src)
    {:ok, wasm, _} = Compilers.rust_compile_to_wasm(p, no_exceptions: true, allow_undefined: true)
    wasm
  end

  @tag :build
  @tag timeout: 300_000
  test "ambient caps — host_now (clock) + host_vfs roundtrip on :minimal profile" do
    w =
      build!(~S|
extern "C" {
  fn host_now() -> i64;
  fn host_vfs_write(pp:i32,pl:i32,dp:i32,dl:i32) -> i32;
  fn host_vfs_read(pp:i32,pl:i32,op:i32,oc:i32) -> i32;
}
fn main(){
  let t = unsafe { host_now() };
  let p="k"; let d="v42";
  unsafe { host_vfs_write(p.as_ptr() as i32, p.len() as i32, d.as_ptr() as i32, d.len() as i32); }
  let mut b=[0u8;64];
  let n = unsafe { host_vfs_read(p.as_ptr() as i32, p.len() as i32, b.as_mut_ptr() as i32, 64) };
  let got = std::str::from_utf8(&b[..n.max(0) as usize]).unwrap_or("");
  println!("now_ok={} vfs={}", t>0, got);
}|)

    assert {:ok, out} = RustDock.run(w, profile: :minimal)
    assert String.trim(out) == "now_ok=true vfs=v42"
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 300_000
  test "egress GATED — host_http_get present on :network, absent on :minimal" do
    assert "host_http_get" in (RustDock.imports(profile: :network)["env"] |> Map.keys())
    refute "host_http_get" in (RustDock.imports(profile: :minimal)["env"] |> Map.keys())

    w =
      build!(~S|
extern "C" { fn host_http_get(up:i32,ul:i32,op:i32,oc:i32) -> i32; }
fn main(){
  let url="http://example.com"; let mut b=[0u8;4096];
  let n = unsafe { host_http_get(url.as_ptr() as i32, url.len() as i32, b.as_mut_ptr() as i32, 4096) };
  let body = if n>0 { std::str::from_utf8(&b[..n as usize]).unwrap_or("") } else { "" };
  println!("bytes_gt0={} has_example={}", n>0, body.contains("Example"));
}|)

    case RustDock.run(w, profile: :network) do
      {:ok, out} -> assert String.trim(out) == "bytes_gt0=true has_example=true"
      {:error, reason} -> IO.puts("\n[skip] http (network-less CI?): #{inspect(reason) |> String.slice(0, 80)}")
    end
  end
end
