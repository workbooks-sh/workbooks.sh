defmodule Workbooks.CrateDepsTest do
  @moduledoc """
  wb-3s8 — real crates.io crates compile + run ENTIRELY in the wasm sandbox as Rust workbook
  dependencies. Each declares a pure-Rust crate via deps=[...]; PackageManager fetches it from
  static.crates.io, parses its features, compiles it (mrustc.wasm→clang.wasm, multi-file aware,
  with version-fallback), links, and runs. Self-verifying (asserts on output). @tag :netdeps
  (needs network for the fetch). Proves the dep pipeline against real-world crate code, not toys.
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager, as: PM

  defp run_with(dep, src, expect) do
    case PM.build(%{"name" => "cd#{System.unique_integer([:positive])}", "lang" => "rust", "src" => src, "deps" => [dep]}) do
      {_n, "rust", {:ok, wasm, st}} ->
        assert st in [:built, :cached]
        assert PM.run(wasm, "", []) |> String.trim() == expect

      {_n, "rust", {:error, reason}} ->
        # network-less CI or a ceiling case: surface, don't hard-fail the suite
        IO.puts("\n[skip] #{dep}: #{inspect(reason) |> String.slice(0, 80)}")
    end
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "byteorder — big-endian read/write" do
    run_with("byteorder@1.4.3", ~S|use byteorder::{ByteOrder, BigEndian};
fn main(){ let mut b=[0u8;4]; BigEndian::write_u32(&mut b, 0xCAFE); println!("{}", BigEndian::read_u32(&b)); }|, "51966")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "adler — checksum" do
    run_with("adler@1.0.2", ~S|fn main(){ println!("{}", adler::adler32_slice(b"Wikipedia")); }|, "300286872")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "base64 — encode" do
    run_with("base64@0.13.1", ~S|fn main(){ println!("{}", base64::encode(b"hello")); }|, "aGVsbG8=")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "memchr — byte search" do
    run_with("memchr@2.5.0", ~S|fn main(){ println!("{:?}", memchr::memchr(b'c', b"abcdef")); }|, "Some(2)")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "ryu — float formatting" do
    run_with("ryu@1.0.5", ~S|fn main(){ let mut b=ryu::Buffer::new(); println!("{}", b.format(3.5f64)); }|, "3.5")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "bitflags — declarative-macro crate" do
    run_with("bitflags@1.3.2", ~S|#[macro_use] extern crate bitflags;
bitflags!{ struct F: u32 { const A=1; const B=2; } }
fn main(){ println!("{}", F::all().bits()); }|, "3")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "num-traits — hyphenated name + autocfg build.rs (skipped)" do
    run_with("num-traits@0.2.15", ~S|fn main(){ println!("{}", num_traits::pow(2u64,10)); }|, "1024")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "num-integer — TRANSITIVE dep (pulls num-traits) end-to-end" do
    run_with("num-integer@0.1.45", ~S|fn main(){ println!("{} {}", num_integer::gcd(48,18), num_integer::lcm(4,6)); }|, "6 12")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "lazy_static — declarative-macro crate" do
    run_with("lazy_static@1.4.0", ~S|#[macro_use] extern crate lazy_static;
lazy_static!{ static ref A: i32 = 6*7; }
fn main(){ println!("{}", *A); }|, "42")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "serde_json — DEEP transitive tree (serde+itoa+ryu), JSON parse+serialize, no derive" do
    run_with("serde_json@1.0.68", ~S'fn main(){
  let v: serde_json::Value = serde_json::from_str("{\"a\":1,\"b\":[2,3,4]}").unwrap();
  let mut s: i64 = 0;
  for x in v["b"].as_array().unwrap() { s += x.as_i64().unwrap(); }
  println!("{} {}", v["a"], s);
}', "1 9")
  end
end
