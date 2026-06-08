defmodule Workbooks.StressTest do
  @moduledoc """
  Stress the in-sandbox compiler lanes (wb-fm0) with DEMANDING programs — collections,
  generics, closures, JSON, regex, generators, allocators, hashing, reflection — not
  hello-worlds. Every program compiles + runs ENTIRELY in the wasm sandbox (no native
  toolchain) and its EXACT output is checked. @tag :build (needs the provisioned toolchains;
  run compilers/*/build.sh + compilers/rust/provision-rust.sh first).
  """
  use ExUnit.Case, async: false
  alias Workbooks.PackageManager, as: PM

  defp build_run(lang, src, input) do
    {_n, ^lang, {:ok, wasm, _}} =
      PM.build(%{"name" => "st#{System.unique_integer([:positive])}", "lang" => lang, "src" => src})

    PM.run(wasm, input, []) |> to_string() |> String.trim()
  end

  @tag :build
  @tag timeout: 300_000
  test "C: qsort + math + string ops" do
    src = ~S"""
    #include <stdio.h>
    #include <stdlib.h>
    #include <math.h>
    #include <string.h>
    static int cmp(const void*a,const void*b){return *(const int*)a-*(const int*)b;}
    int main(){ int a[]={5,3,8,1,9,2,7}; qsort(a,7,sizeof(int),cmp);
     long s=0; for(int i=0;i<7;i++) s+=a[i];
     char b[64]; strcpy(b,"hello"); strcat(b," world");
     printf("sorted=%d..%d sum=%ld sqrt2k=%.0f s=%s len=%zu\n",a[0],a[6],s,sqrt(2.0)*1000,b,strlen(b)); return 0; }
    """

    assert build_run("c", src, "") =~ "sorted=1..9 sum=35 sqrt2k=1414 s=hello world len=11"
  end

  @tag :build
  @tag timeout: 900_000
  test "Rust: HashMap (hashing) + iterators + sort + format" do
    src = ~S"""
    use std::collections::HashMap;
    fn main(){
      let mut m: HashMap<String,i32> = HashMap::new();
      for w in "the cat sat on the mat the cat".split_whitespace() { *m.entry(w.to_string()).or_insert(0)+=1; }
      let mut v: Vec<_> = m.into_iter().collect(); v.sort();
      let total: i32 = v.iter().map(|(_,c)| *c).sum();
      println!("{:?} total={}", v, total);
    }
    """

    out = build_run("rust", src, "")
    assert out =~ "total=8"
    assert out =~ ~S|("the", 3)|
  end

  @tag :build
  @tag timeout: 900_000
  test "Rust: HashMap correct AT SCALE (5000 entries, resize/collisions, iteration)" do
    # Guards the wb-ar7 fix: the neutered hashbrown debug_assert could have hidden a real
    # miscompile that only bites large maps. This proves insert/get/iterate are correct at
    # scale — iter_count must equal len (the exact invariant the assert checked).
    src = ~S"""
    use std::collections::HashMap;
    fn main(){
      let n: u32 = 5000;
      let mut m = HashMap::new();
      for i in 0..n { m.insert(i, i.wrapping_mul(i)); }
      let mut ok = true;
      for i in 0..n { if m.get(&i) != Some(&i.wrapping_mul(i)) { ok = false; break; } }
      let mut count: u64 = 0; let mut sum: u64 = 0;
      for (k, v) in &m { count += 1; sum = sum.wrapping_add(*v as u64); if *v != k.wrapping_mul(*k) { ok = false; } }
      let expected: u64 = (0..n).map(|i| i.wrapping_mul(i) as u64).fold(0u64, |a,b| a.wrapping_add(b));
      println!("len={} ok={} iter_count={} sum_ok={}", m.len(), ok, count, sum == expected);
    }
    """

    assert build_run("rust", src, "") == "len=5000 ok=true iter_count=5000 sum_ok=true"
  end

  @tag :build
  @tag timeout: 300_000
  test "JS: generators + destructuring + Map + regex + JSON" do
    src = ~S"""
    function* fib(){ let a=0,b=1; for(;;){ yield a; [a,b]=[b,a+b]; } }
    const g=fib(), seq=[]; for(let i=0;i<10;i++) seq.push(g.next().value);
    const m=new Map(); "the cat sat the".split(" ").forEach(w=>m.set(w,(m.get(w)||0)+1));
    const o={fib:seq,the:m.get("the"),d:"a1b2c3".match(/\d/g)};
    Javy.IO.writeSync(1,new TextEncoder().encode(JSON.stringify(o)+"\n"));
    """

    assert build_run("js", src, "") =~ ~S|"fib":[0,1,1,2,3,5,8,13,21,34],"the":2,"d":["1","2","3"]|
  end

  @tag :build
  @tag timeout: 300_000
  test "Go (yaegi): maps + sort + encoding/json reflection" do
    src = ~S"""
    package main
    import ("encoding/json";"fmt";"sort";"strings")
    func main(){
      m := map[string]int{}
      for _, w := range strings.Fields("the cat sat on the mat the cat") { m[w]++ }
      keys := []string{}; for k := range m { keys = append(keys, k) }; sort.Strings(keys)
      b,_ := json.Marshal(m)
      fmt.Printf("keys=%v jsonlen=%d the=%d\n", keys, len(b), m["the"])
    }
    """

    out = build_run("go", src, "")
    assert out =~ "keys=[cat mat on sat the]"
    assert out =~ "the=3"
  end

  @tag :build
  @tag timeout: 300_000
  test "TypeScript: enum (non-erasable) + generic class + methods" do
    src = ~S"""
    enum Color { Red, Green, Blue }
    class Box<T> { constructor(public v: T){} map<U>(f:(t:T)=>U): Box<U>{ return new Box(f(this.v)); } }
    const b = new Box<number>(21).map(x => x*2);
    Javy.IO.writeSync(1, new TextEncoder().encode(`enum=${Color.Blue} box=${b.v}\n`));
    """

    assert build_run("ts", src, "") =~ "enum=2 box=42"
  end

  @tag :build
  @tag timeout: 600_000
  test "Zig: recursion + struct + std.fmt" do
    src = ~S"""
    const std = @import("std");
    fn fib(n: u32) u64 { return if (n < 2) n else fib(n-1) + fib(n-2); }
    pub fn main() void {
      const Pt = struct { x: i32, y: i32 };
      const p = Pt{ .x = 3, .y = 4 };
      std.debug.print("fib20={d} dist2={d}\n", .{ fib(20), p.x*p.x + p.y*p.y });
    }
    """

    assert build_run("zig", src, "") =~ "fib20=6765 dist2=25"
  end
end
