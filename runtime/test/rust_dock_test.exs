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

  test "least-privilege: dedicated exec/kv caps gate the brokers (compute profile is denied them)" do
    min = RustDock.imports(profile: :minimal)["env"] |> Map.keys()
    assert "host_exec" in min
    assert "host_kv_put" in min
    assert "host_parallel_map" in min

    # compute has only the `vfs` cap — NO exec, NO durable kv: a profile can grant compute/storage without
    # granting the ability to spawn commands.
    compute = RustDock.imports(profile: :compute)["env"] |> Map.keys()
    refute "host_exec" in compute
    refute "host_kv_put" in compute
    refute "host_kv_get" in compute
    refute "host_parallel_map" in compute
  end

  @tag :build
  @tag timeout: 300_000
  test "host_exec — guest brokers exec to a SANDBOXED coreutils (seq) end-to-end (Stone 2)" do
    # gated on the commands cap (present on :minimal); the guest builds the length-prefixed request,
    # calls host_exec, the host runs coreutils in its own sandbox, the output comes back.
    assert "host_exec" in (RustDock.imports(profile: :minimal)["env"] |> Map.keys())
    assert :ok = Workbooks.Pallet.seed_one("coreutils")

    w =
      build!(~S|
extern "C" { fn host_exec(rp:i32,rl:i32,op:i32,oc:i32) -> i32; }
fn le(n:u32, b:&mut Vec<u8>){ b.extend_from_slice(&n.to_le_bytes()); }
fn main(){
  // [name_len][name][argc][(arg_len)(arg)]*[stdin_len][stdin]
  let name:&[u8]=b"coreutils";
  let args:[&[u8];2]=[b"seq", b"5"];
  let mut req:Vec<u8>=Vec::new();
  le(name.len() as u32,&mut req); req.extend_from_slice(name);
  le(args.len() as u32,&mut req);
  for a in args.iter(){ le(a.len() as u32,&mut req); req.extend_from_slice(a); }
  le(0u32,&mut req); // empty stdin
  let mut out=[0u8;256];
  let n=unsafe{ host_exec(req.as_ptr() as i32, req.len() as i32, out.as_mut_ptr() as i32, 256) };
  let expected:&[u8]=b"1\n2\n3\n4\n5"; // CommandRegistry maybe_trim strips the trailing newline (9 bytes)
  let ok = n==9 && &out[..(if n>0 {n as usize} else {0})]==expected;
  println!("n={} ok={}", n, ok);
}|)

    assert {:ok, out} = RustDock.run(w, profile: :minimal)
    assert String.trim(out) == "n=9 ok=true"
  end

  @tag :build
  @tag timeout: 300_000
  test "host_kv — durable per-tenant storage: persists across runs + isolated between tenants (Stone 3)" do
    assert "host_kv_put" in (RustDock.imports(profile: :minimal)["env"] |> Map.keys())
    u = System.unique_integer([:positive])
    ta = "e2e-#{u}-A"
    tb = "e2e-#{u}-B"

    w =
      build!(~S|
extern "C" {
  fn host_kv_put(kp:i32,kl:i32,vp:i32,vl:i32) -> i32;
  fn host_kv_get(kp:i32,kl:i32,op:i32,oc:i32) -> i32;
}
fn main(){
  let k=b"slot"; let mut out=[0u8;64];
  let n=unsafe{ host_kv_get(k.as_ptr() as i32,k.len() as i32, out.as_mut_ptr() as i32, 64) };
  if n>0 {
    let got=std::str::from_utf8(&out[..n as usize]).unwrap_or("");
    println!("found={}", got);
  } else {
    let v=b"durable-v1";
    let r=unsafe{ host_kv_put(k.as_ptr() as i32,k.len() as i32, v.as_ptr() as i32, v.len() as i32) };
    println!("stored r={}", r);
  }
}|)

    # run 1 (tenant A): empty -> stores
    assert {:ok, o1} = RustDock.run(w, profile: :minimal, tenant: ta)
    assert String.trim(o1) == "stored r=0"
    # run 2 (tenant A): the value PERSISTED across runs (durable through the broker)
    assert {:ok, o2} = RustDock.run(w, profile: :minimal, tenant: ta)
    assert String.trim(o2) == "found=durable-v1"
    # run 3 (tenant B): ISOLATED — B's namespace is empty, it never sees A's "slot"
    assert {:ok, o3} = RustDock.run(w, profile: :minimal, tenant: tb)
    assert String.trim(o3) == "stored r=0"
  end

  @tag :build
  @tag timeout: 300_000
  test "host_parallel_map — guest fans a command over N inputs CONCURRENTLY (Stone 4)" do
    assert "host_parallel_map" in (RustDock.imports(profile: :minimal)["env"] |> Map.keys())
    assert :ok = Workbooks.Pallet.seed_one("coreutils")

    w =
      build!(~S|
extern "C" { fn host_parallel_map(rp:i32,rl:i32,op:i32,oc:i32) -> i32; }
fn le(n:u32, b:&mut Vec<u8>){ b.extend_from_slice(&n.to_le_bytes()); }
fn rd(b:&[u8],p:usize)->i32{ i32::from_le_bytes([b[p],b[p+1],b[p+2],b[p+3]]) }
fn main(){
  // [name_len][name][argc][(arg_len)(arg)]*[ninputs][(input_len)(input)]*
  let name=b"coreutils"; let args:[&[u8];1]=[b"cat"]; let inputs:[&[u8];3]=[b"alpha",b"beta",b"gamma"];
  let mut req:Vec<u8>=Vec::new();
  le(name.len() as u32,&mut req); req.extend_from_slice(name);
  le(args.len() as u32,&mut req); for a in args.iter(){ le(a.len() as u32,&mut req); req.extend_from_slice(a); }
  le(inputs.len() as u32,&mut req); for i in inputs.iter(){ le(i.len() as u32,&mut req); req.extend_from_slice(i); }
  let mut out=[0u8;512];
  let total=unsafe{ host_parallel_map(req.as_ptr() as i32, req.len() as i32, out.as_mut_ptr() as i32, 512) };
  if total<4 { println!("err total={}", total); return; }
  let mut p=0usize; let n=rd(&out,p); p+=4;
  let mut parts:Vec<String>=Vec::new();
  for _ in 0..n {
    let len=rd(&out,p); p+=4;
    if len<0 { parts.push(String::from("ERR")); }
    else { parts.push(std::str::from_utf8(&out[p..p+len as usize]).unwrap_or("?").to_string()); p+=len as usize; }
  }
  println!("n={} results={}", n, parts.join(","));
}|)

    assert {:ok, out} = RustDock.run(w, profile: :minimal)
    assert String.trim(out) == "n=3 results=alpha,beta,gamma"
  end

  @tag :build
  @tag timeout: 300_000
  test "host_sign — guest signs with a host-held secret it NEVER sees (brokered secrets)" do
    assert "host_sign" in (RustDock.imports(profile: :minimal)["env"] |> Map.keys())
    tenant = "sec-#{System.unique_integer([:positive])}"
    secret = "super-secret-#{System.unique_integer([:positive])}"
    assert :ok = Workbooks.SecretBroker.register(tenant, "apikey", secret)

    # The guest sends only the secret NAME + the data; it gets back the HMAC, never the secret value.
    w =
      build!(~S|
extern "C" { fn host_sign(np:i32,nl:i32,dp:i32,dl:i32,op:i32,oc:i32) -> i32; }
fn main(){
  let name=b"apikey"; let data=b"payload"; let mut out=[0u8;32];
  let n = unsafe { host_sign(name.as_ptr() as i32, name.len() as i32, data.as_ptr() as i32, data.len() as i32, out.as_mut_ptr() as i32, 32) };
  let mut hex = String::new();
  if n>0 { for b in out[..(n as usize)].iter() { hex.push_str(&format!("{:02x}", b)); } }
  println!("sig={}", hex);
}|)

    assert {:ok, out} = RustDock.run(w, profile: :minimal, tenant: tenant)
    expected = :crypto.mac(:hmac, :sha256, secret, "payload") |> Base.encode16(case: :lower)
    assert String.trim(out) == "sig=" <> expected
  end

  @tag :build
  @tag timeout: 300_000
  test "host_publish/host_poll — a PRODUCER guest hands a message to a separate CONSUMER guest (inter-guest)" do
    assert "host_publish" in (RustDock.imports(profile: :minimal)["env"] |> Map.keys())
    tenant = "q-#{System.unique_integer([:positive])}"

    producer =
      build!(~S|
extern "C" { fn host_publish(tp:i32,tl:i32,mp:i32,ml:i32) -> i32; }
fn main(){ let t=b"jobs"; let m=b"job-42";
  let r=unsafe{host_publish(t.as_ptr() as i32,t.len() as i32,m.as_ptr() as i32,m.len() as i32)};
  println!("pub={}", r); }|)

    consumer =
      build!(~S|
extern "C" { fn host_poll(tp:i32,tl:i32,op:i32,oc:i32) -> i32; }
fn main(){ let t=b"jobs"; let mut o=[0u8;64];
  let n=unsafe{host_poll(t.as_ptr() as i32,t.len() as i32,o.as_mut_ptr() as i32,64)};
  let g=if n>0{std::str::from_utf8(&o[..n as usize]).unwrap_or("")}else{"EMPTY"};
  println!("got={}", g); }|)

    # producer guest enqueues; a SEPARATE consumer guest (same tenant) drains it
    assert {:ok, o1} = RustDock.run(producer, profile: :minimal, tenant: tenant)
    assert String.trim(o1) == "pub=0"
    assert {:ok, o2} = RustDock.run(consumer, profile: :minimal, tenant: tenant)
    assert String.trim(o2) == "got=job-42"
  end
end
