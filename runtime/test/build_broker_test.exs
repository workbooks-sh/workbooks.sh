defmodule Workbooks.BuildBrokerTest do
  use ExUnit.Case, async: false
  alias Workbooks.BuildBroker

  test "DEFAULT-DENY — a build without the grant is refused (no compile happens)" do
    assert {:error, :denied} = BuildBroker.build_and_run(:c, "int main(){return 0;}", "")
  end

  test "SOURCE BYTE CAP — an oversized source is refused before compiling" do
    big = String.duplicate("/* x */\n", 200_000)
    assert {:error, :source_too_large} =
             BuildBroker.build_and_run(:c, big, "", allow: true, max_source: 1024)
  end

  test "REVOCATION — a revoked principal cannot build" do
    p = "build-rev-#{System.unique_integer([:positive])}"
    :ok = Workbooks.Revocation.revoke(p)
    assert {:error, :revoked} = BuildBroker.build_and_run(:c, "int main(){return 0;}", "", allow: true, principal: p)
    :ok = Workbooks.Revocation.unrevoke(p)
  end

  test "unsupported language is refused" do
    assert {:error, :unsupported_lang} = BuildBroker.build_and_run(:cobol, "x", "", allow: true)
  end

  @tag :build
  @tag timeout: 300_000
  test "BROKERED BUILD+RUN (C) — source becomes a sandboxed tool that runs (full stack)" do
    src = ~S|
#include <stdio.h>
int main(void){ int x; if(scanf("%d",&x)==1) printf("doubled=%d\n", x*2); return 0; }
|
    assert {:ok, out} = BuildBroker.build_and_run(:c, src, "21\n", allow: true)
    assert out =~ "doubled=42"
  end

  @tag :build
  @tag timeout: 600_000
  test "BROKERED BUILD+RUN (Rust) — Rust source becomes a sandboxed tool that runs" do
    src = ~S|
use std::io::Read;
fn main(){ let mut s=String::new(); std::io::stdin().read_to_string(&mut s).unwrap();
  println!("upper={}", s.trim().to_uppercase()); }
|
    assert {:ok, out} = BuildBroker.build_and_run(:rust, src, "hello brokered build\n", allow: true)
    assert out =~ "upper=HELLO BROKERED BUILD"
  end
end
