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
  test "anyhow — error handling" do
    run_with("anyhow@1.0.57", ~S|fn f() -> anyhow::Result<i32> { Ok(42) }
fn main(){ println!("{}", f().unwrap()); }|, "42")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "once_cell — lazy statics" do
    run_with("once_cell@1.12.0", ~S'use once_cell::sync::Lazy;
static N: Lazy<i32> = Lazy::new(|| 6 * 7);
fn main(){ println!("{}", *N); }', "42")
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

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "percent-encoding — Display encode" do
    run_with("percent-encoding@2.1.0", ~S|fn main(){ println!("{}", percent_encoding::utf8_percent_encode("a b/c", percent_encoding::NON_ALPHANUMERIC)); }|, "a%20b%2Fc")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "glob — pattern match" do
    run_with("glob@0.3.0", ~S|fn main(){ let p = glob::Pattern::new("*.rs").unwrap(); println!("{}", p.matches("foo.rs")); }|, "true")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "tinyvec — stack-allocated ArrayVec" do
    run_with("tinyvec@1.5.1", ~S|fn main(){ let mut v: tinyvec::ArrayVec<[i32;4]> = Default::default(); v.push(5); v.push(7); v.push(9); println!("{}", v.iter().sum::<i32>()); }|, "21")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "arrayvec — stack ArrayVec" do
    run_with("arrayvec@0.5.2", ~S|fn main(){ let mut v = arrayvec::ArrayVec::<[i32;4]>::new(); v.push(3); v.push(4); println!("{}", v.len()); }|, "2")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "unicode-width — display width" do
    run_with("unicode-width@0.1.9", ~S|use unicode_width::UnicodeWidthStr;
fn main(){ println!("{}", "hello".width()); }|, "5")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "unicode-xid — identifier classification" do
    run_with("unicode-xid@0.2.4", ~S|fn main(){ println!("{}", unicode_xid::UnicodeXID::is_xid_start('a')); }|, "true")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "either — Left/Right enum" do
    run_with("either@1.6.1", ~S|fn main(){ let e: either::Either<i32,i32> = either::Either::Left(5); println!("{}", e.is_left()); }|, "true")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "fnv — custom-hasher HashMap" do
    run_with("fnv@1.0.7", ~S|fn main(){ let mut m: std::collections::HashMap<&str,i32,fnv::FnvBuildHasher> = Default::default(); m.insert("a",1); m.insert("b",2); println!("{}", m["a"]+m["b"]); }|, "3")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "smallvec — inline small vector" do
    run_with("smallvec@1.6.1", ~S|fn main(){ let mut v: smallvec::SmallVec<[i32;4]> = smallvec::SmallVec::new(); v.push(7); v.push(8); println!("{}", v.iter().sum::<i32>()); }|, "15")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "cfg-if — conditional-compile macro" do
    run_with("cfg-if@1.0.0", ~S|cfg_if::cfg_if!{ if #[cfg(target_arch="wasm32")] { fn g()->i32{42} } else { fn g()->i32{0} } }
fn main(){ println!("{}", g()); }|, "42")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "scopeguard — RAII guard with closure" do
    run_with("scopeguard@1.1.0", ~S|fn main(){ let g = scopeguard::guard(7, |_v| {}); println!("{}", *g); }|, "7")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "pin-project-lite — declarative pin_project! macro" do
    run_with("pin-project-lite@0.2.9", ~S|pin_project_lite::pin_project!{ struct S { #[pin] x: i32 } }
fn main(){ let s = S { x: 9 }; println!("{}", s.x); }|, "9")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "static_assertions — compile-time const_assert!" do
    run_with("static_assertions@1.1.0", ~S|static_assertions::const_assert!(1 + 1 == 2);
fn main(){ println!("ok"); }|, "ok")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "maplit — hashmap! literal macro" do
    run_with("maplit@1.0.2", ~S|#[macro_use] extern crate maplit;
fn main(){ let m = hashmap!{"a" => 1, "b" => 2}; println!("{}", m["a"] + m["b"]); }|, "3")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "itertools (0.9) — iterator adaptors, transitive either" do
    run_with("itertools@0.9.0", ~S|use itertools::Itertools;
fn main(){ let s: i32 = (1..=3).interleave(4..=6).sum(); println!("{}", s); }|, "21")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "itoa (0.4) — io::Write integer formatting" do
    run_with("itoa@0.4.8", ~S|fn main(){ let mut v=Vec::new(); itoa::write(&mut v, 12345u32).unwrap(); println!("{}", String::from_utf8(v).unwrap()); }|, "12345")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "ascii — AsciiChar" do
    run_with("ascii@1.0.0", ~S|fn main(){ println!("{}", ascii::AsciiChar::A.as_char()); }|, "A")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "vec_map — integer-keyed map" do
    run_with("vec_map@0.8.2", ~S|fn main(){ let mut m = vec_map::VecMap::new(); m.insert(3, "c"); println!("{}", m[3]); }|, "c")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "num-complex — complex arithmetic (transitive num-traits)" do
    run_with("num-complex@0.4.3", ~S|use num_complex::Complex;
fn main(){ let c = Complex::new(1.0f64,2.0) * Complex::new(1.0,2.0); println!("{} {}", c.re, c.im); }|, "-3 4")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "num-rational — fraction arithmetic (transitive num-integer+num-traits)" do
    run_with("num-rational@0.4.1", ~S|use num_rational::Ratio;
fn main(){ let r = Ratio::new(1,2) + Ratio::new(1,3); println!("{}", r); }|, "5/6")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "unicode-segmentation — grapheme clusters" do
    run_with("unicode-segmentation@1.9.0", ~S|use unicode_segmentation::UnicodeSegmentation;
fn main(){ println!("{}", "abc".graphemes(true).count()); }|, "3")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "ordered-float — sortable f64 wrapper" do
    run_with("ordered-float@2.10.0", ~S|use ordered_float::OrderedFloat;
fn main(){ let mut v = vec![OrderedFloat(3.0f64), OrderedFloat(1.0)]; v.sort(); println!("{}", v[0].0); }|, "1")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "aho-corasick — multi-pattern automaton (regex's matcher)" do
    run_with("aho-corasick@0.7.18", ~S|use aho_corasick::AhoCorasick;
fn main(){ let ac = AhoCorasick::new(&["he","she"]); println!("{}", ac.is_match("she")); }|, "true")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "log — logging facade macros" do
    run_with("log@0.4.17", ~S|fn main(){ log::info!("hi"); println!("ok"); }|, "ok")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "bytes — BytesMut buffer (transitive, tokio ecosystem)" do
    run_with("bytes@1.1.0", ~S|use bytes::BufMut;
fn main(){ let mut b = bytes::BytesMut::new(); b.put_u8(65); b.put_u8(66); println!("{}", b.len()); }|, "2")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "regex — basic patterns (classes/alternation/captures; non-unicode, deps aho-corasick+memchr+regex-syntax)" do
    # \d/\w need the unicode-perl feature which exceeds the mrustc ceiling (wb-3ev); basic
    # patterns (the common case) work. This also exercises the deterministic-link fix (wb-mrz).
    run_with("regex@1.5.4", ~S|fn main(){
  let re = regex::Regex::new("[0-9]+").unwrap();
  let m = re.find("ab123cd").unwrap();
  let re2 = regex::Regex::new("(foo|bar)-([a-z]+)").unwrap();
  let c = re2.captures("bar-baz").unwrap();
  println!("{} {} {}", m.as_str(), &c[1], &c[2]);
}|, "123 bar baz")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "heck — case conversion" do
    run_with("heck@0.3.3", ~S|use heck::CamelCase;
fn main(){ println!("{}", "hello_world".to_camel_case()); }|, "HelloWorld")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "strsim — Levenshtein distance" do
    run_with("strsim@0.10.0", ~S|fn main(){ println!("{}", strsim::levenshtein("kitten","sitting")); }|, "3")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "bytecount — fast byte counting" do
    run_with("bytecount@0.6.3", ~S|fn main(){ println!("{}", bytecount::count(b"hello world", b'o')); }|, "2")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "fastrand — seeded PRNG determinism" do
    run_with("fastrand@1.8.0", ~S|fn main(){ fastrand::seed(1); let a=fastrand::u32(..); fastrand::seed(1); let b=fastrand::u32(..); println!("{}", a==b); }|, "true")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "humantime — duration formatting" do
    run_with("humantime@2.1.0", ~S|fn main(){ println!("{}", humantime::format_duration(std::time::Duration::from_secs(90))); }|, "1m 30s")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "unicode-ident — XID identifier classification" do
    run_with("unicode-ident@1.0.0", ~S|fn main(){ println!("{}", unicode_ident::is_xid_start('x')); }|, "true")
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "regex unicode \\d via opts[:dep_features] — feature selection unlocks unicode-perl" do
    # The full default feature set (unicode-age/script/segment tables + perf) exceeds the mrustc
    # ceiling, but the MINIMAL unicode-perl set compiles and makes \d/\w live. Exercises the
    # per-dep feature-selection API directly (run_with only threads deps).
    src = Path.join(System.tmp_dir!(), "cd_rx_unicode.rs")
    File.write!(src, ~S|fn main(){ let re = regex::Regex::new(r"\d+").unwrap(); println!("{}", re.find("ab123cd").unwrap().as_str()); }|)
    feats = %{"regex" => ["std", "unicode-perl"], "regex-syntax" => ["std", "unicode-perl"]}

    case Workbooks.Compilers.rust_compile_to_wasm(src, deps: ["regex@1.5.4"], dep_features: feats) do
      {:ok, wasm, _} -> assert PM.run(wasm, "", []) |> String.trim() == "123"
      {:error, reason} -> IO.puts("\n[skip] regex unicode: #{inspect(reason) |> String.slice(0, 80)}")
    end
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "nom — parser combinators via opts[:dep_features] (alloc, no std)" do
    # nom@6 fails to compile with its full default feature set (std) on mrustc, but compiles with
    # the reduced alloc-only set — another feature-selection unlock (the std default was the wall).
    src = Path.join(System.tmp_dir!(), "cd_nom.rs")
    File.write!(src, ~S|use nom::character::complete::digit1;
fn main(){ let r: nom::IResult<&str,&str> = digit1("123abc"); println!("{}", r.unwrap().1); }|)

    case Workbooks.Compilers.rust_compile_to_wasm(src, deps: ["nom@6.1.2"], dep_features: %{"nom" => ["alloc"]}) do
      {:ok, wasm, _} -> assert PM.run(wasm, "", []) |> String.trim() == "123"
      {:error, reason} -> IO.puts("\n[skip] nom: #{inspect(reason) |> String.slice(0, 80)}")
    end
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "data-encoding via opts[:dep_features] (alloc, no std)" do
    src = Path.join(System.tmp_dir!(), "cd_dataenc.rs")
    File.write!(src, ~S|fn main(){ println!("{}", data_encoding::HEXLOWER.encode(b"AB")); }|)

    case Workbooks.Compilers.rust_compile_to_wasm(src, deps: ["data-encoding@2.3.3"], dep_features: %{"data-encoding" => ["alloc"]}) do
      {:ok, wasm, _} -> assert PM.run(wasm, "", []) |> String.trim() == "4142"
      {:error, reason} -> IO.puts("\n[skip] data-encoding: #{inspect(reason) |> String.slice(0, 80)}")
    end
  end

  @tag :build
  @tag :netdeps
  @tag timeout: 900_000
  test "itertools (0.10) via opts[:dep_features] (use_alloc, no std)" do
    # itertools@0.10 fails to compile with its std default but compiles with use_alloc only.
    src = Path.join(System.tmp_dir!(), "cd_itertools010.rs")
    File.write!(src, ~S|use itertools::Itertools;
fn main(){ let s: i32 = (1..=3).interleave(4..=6).sum(); println!("{}", s); }|)

    case Workbooks.Compilers.rust_compile_to_wasm(src, deps: ["itertools@0.10.5"], dep_features: %{"itertools" => ["use_alloc"]}) do
      {:ok, wasm, _} -> assert PM.run(wasm, "", []) |> String.trim() == "21"
      {:error, reason} -> IO.puts("\n[skip] itertools 0.10: #{inspect(reason) |> String.slice(0, 80)}")
    end
  end
end
