defmodule Workbooks.BuildBroker do
  @moduledoc """
  wb-broker BUILD-FROM-SOURCE (the build-orchestration lane) — the host-brokered "compile this source into a
  runnable tool, then run it", the privileged op a sandboxed guest can't do itself (it has no compiler/OS).
  This is the foundation the fork-exec (36) + heavy-build-system (37) reclaim buckets need: a tool that builds
  OTHER tools (a make-like driver, a package installer) does it by spawning compiles — here that spawn is
  BROKERED, the compile runs ENTIRELY in-sandbox (Compilers / clang.wasm + mrustc, zero native toolchain), and
  the produced tool runs SANDBOXED (wasmtime, no caps unless granted). Proven recipes (iter129-131) wrapped in
  the broker cadence.

  Security cadence (mirrors the exec broker):
    * DEFAULT-DENY — a guest may build only if granted (`:allow`, from the `commands`/build cap).
    * SOURCE + OUTPUT byte caps — a huge source or huge produced tool can't exhaust the host.
    * per-principal RATE + REVOCATION — a runaway build loop is throttled; a revoked principal can't build.
    * SANDBOXED COMPILE + RUN — the compiler runs in wasmtime (a malicious source can at most abuse its own
      compiler instance, never escape); the built tool runs with NO network and NO fs preopen by default.
    * AUDIT on every denial (:build).
  """
  @langs [:c, :rust]
  @default_max_source 1024 * 1024
  @default_max_output 16 * 1024 * 1024

  # wb_broker.h — the canonical ergonomic shim for the host-brokered transport (PyNet file protocol over the
  # preopened /b dir). A C tool `#include "wb_broker.h"` and calls wb_http_get()/wb_exec(); the HOST does the
  # privileged op (SSRF-mediated egress / ExecBroker dispatch), the guest only reads/writes files. Self-
  # contained (base64 decode + flat-JSON value extraction inline) so no libs are needed in the sandbox.
  @broker_header ~S"""
  #ifndef WB_BROKER_H
  #define WB_BROKER_H
  #include <stdio.h>
  #include <string.h>
  #include <unistd.h>

  static const char WB__B64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  static int wb__b64val(char c){ const char *p = c ? strchr(WB__B64, c) : 0; return p ? (int)(p - WB__B64) : -1; }

  /* decode base64 `in` (inlen chars) into `out` (cap bytes); returns decoded length or -1 on overflow. */
  static int wb__b64dec(const char *in, int inlen, unsigned char *out, int cap){
    int acc=0, bits=0, n=0;
    for(int i=0;i<inlen;i++){ int v=wb__b64val(in[i]); if(v<0) continue;
      acc=(acc<<6)|v; bits+=6; if(bits>=8){ bits-=8; if(n>=cap) return -1; out[n++]=(unsigned char)((acc>>bits)&0xFF); } }
    return n;
  }
  /* copy the quoted string value following `key` in a flat JSON object into val (cap). returns len or -1. */
  static int wb__json_str(const char *json, const char *key, char *val, int cap){
    const char *p=strstr(json,key); if(!p) return -1; p+=strlen(key);
    int n=0; while(*p && *p!='"' && n<cap-1) val[n++]=*p++; val[n]=0; return n;
  }
  /* write a request, poll for the response, read resp.json into resp (cap). returns len or -1 (timeout). */
  static int wb__roundtrip(const char *reqjson, char *resp, int cap){
    FILE *f=fopen("/b/req.json","w"); if(!f) return -1; fputs(reqjson,f); fclose(f);
    f=fopen("/b/req.ready","w"); if(!f) return -1; fputc('1',f); fclose(f);
    for(int i=0;i<1500;i++){ FILE *r=fopen("/b/resp.ready","r");
      if(r){ fclose(r); FILE *rj=fopen("/b/resp.json","r"); if(!rj) return -1;
        int n=(int)fread(resp,1,cap-1,rj); resp[n]=0; fclose(rj); remove("/b/resp.ready"); return n; }
      usleep(20000); }
    return -1;
  }
  /* brokered HTTP GET. writes the response body into out (cap); returns body length or -1 (denied/timeout). */
  static int wb_http_get(const char *url, unsigned char *out, int cap){
    char req[2304]; static char resp[65536], b64[65536];
    snprintf(req,sizeof(req),"{\"method\":\"GET\",\"url\":\"%s\"}",url);
    if(wb__roundtrip(req,resp,sizeof(resp))<0) return -1;
    if(!strstr(resp,"\"ok\":true")) return -1;
    int bl=wb__json_str(resp,"\"body_b64\":\"",b64,sizeof(b64)); if(bl<=0) return 0;
    return wb__b64dec(b64,bl,out,cap);
  }
  /* brokered command exec. `argv_json` is a JSON array literal e.g. "[\"-c\",\".\"]" (or "[]").
     writes the command's stdout into out (cap); returns length, 0 (ran, empty), or -1 (denied/unknown). */
  static int wb_exec(const char *name, const char *argv_json, unsigned char *out, int cap){
    char req[4096]; static char resp[65536], b64[65536];
    snprintf(req,sizeof(req),"{\"kind\":\"exec\",\"name\":\"%s\",\"argv\":%s}",name,argv_json?argv_json:"[]");
    if(wb__roundtrip(req,resp,sizeof(resp))<0) return -1;
    if(!strstr(resp,"\"ok\":true")) return -1;
    int bl=wb__json_str(resp,"\"stdout_b64\":\"",b64,sizeof(b64)); if(bl<0) return -1;
    return bl==0 ? 0 : wb__b64dec(b64,bl,out,cap);
  }
  #endif
  """

  @doc "Materialize the canonical wb_broker.h shim to a temp file; returns its host path (caller cleans up)."
  def broker_header_file do
    path = tmp("wb_broker", ".h")
    File.write!(path, @broker_header)
    path
  end

  @doc """
  Build `source` (a `:c` or `:rust` program string) into a sandboxed wasm tool and RUN it with `stdin`,
  returning its stdout. `{:ok, output}` | `{:error, reason}`. opts: `:allow` (default false), `:principal`,
  `:rate`, `:max_source`, `:max_output`, `:argv`. The compile is in-sandbox; the run is sandboxed (no net/fs).
  """
  def build_and_run(lang, source, stdin \\ "", opts \\ [])
      when is_atom(lang) and is_binary(source) and is_binary(stdin) do
    allow = Keyword.get(opts, :allow, false)
    principal = Keyword.get(opts, :principal)
    rate = Keyword.get(opts, :rate, Workbooks.RateLimiter.default_quota())
    max_source = Keyword.get(opts, :max_source, @default_max_source)
    max_output = Keyword.get(opts, :max_output, @default_max_output)

    cond do
      not allow ->
        deny("not granted (no build cap)")
        {:error, :denied}

      lang not in @langs ->
        deny("unsupported build lang #{inspect(lang)}")
        {:error, :unsupported_lang}

      principal && Workbooks.Revocation.revoked?(principal) ->
        deny("principal revoked")
        {:error, :revoked}

      principal && rate && rate_denied?(principal, rate) ->
        deny("rate limited")
        {:error, :rate_limited}

      byte_size(source) > max_source ->
        deny("source too large")
        {:error, :source_too_large}

      true ->
        broker? = Keyword.get(opts, :broker, false)

        with {:ok, wasm} <- compile(lang, source, broker?) do
          try do
            out = run_built(wasm, stdin, Keyword.get(opts, :argv, []), broker?, opts)
            {:ok, cap(out, max_output)}
          after
            File.rm(wasm)
          end
        end
    end
  end

  @doc "Just build `source` to a wasm tool (no run); returns `{:ok, wasm_path}` | `{:error, _}`. Same cadence."
  def build(lang, source, opts \\ []) when is_atom(lang) and is_binary(source) do
    allow = Keyword.get(opts, :allow, false)
    principal = Keyword.get(opts, :principal)
    max_source = Keyword.get(opts, :max_source, @default_max_source)

    cond do
      not allow -> deny("not granted"); {:error, :denied}
      lang not in @langs -> deny("unsupported lang"); {:error, :unsupported_lang}
      principal && Workbooks.Revocation.revoked?(principal) -> deny("revoked"); {:error, :revoked}
      byte_size(source) > max_source -> deny("source too large"); {:error, :source_too_large}
      true -> compile(lang, source)
    end
  end

  defp compile(lang, source, broker? \\ false)

  defp compile(:c, source, broker?) do
    src = tmp("bb_c", ".c")
    File.write!(src, source)
    # in :broker mode, stage wb_broker.h next to the source so `#include "wb_broker.h"` resolves (compiled-but-
    # not-linked aux file — the shim is header-only/static).
    {header, copts} =
      if broker? do
        h = broker_header_file()
        {h, [aux_files: [{h, "wb_broker.h"}]]}
      else
        {nil, []}
      end

    try do
      case Workbooks.Compilers.compile_c(src, copts) do
        {:ok, wasm, _} -> {:ok, wasm}
        {:error, reason} -> {:error, {:compile_failed, reason}}
      end
    after
      File.rm(src)
      header && File.rm(header)
    end
  end

  defp compile(:rust, source, _broker?) do
    src = tmp("bb_rs", ".rs")
    File.write!(src, source)

    try do
      case Workbooks.Compilers.rust_compile_to_wasm(src, no_exceptions: true) do
        {:ok, wasm, _} -> {:ok, wasm}
        {:error, reason} -> {:error, {:compile_failed, reason}}
      end
    after
      File.rm(src)
    end
  end

  # run the produced tool. PLAIN: sandboxed (no network, no fs preopen). BROKER: through the brokered transport
  # (PyNet.run_wasm) so the tool's wb_http_get/wb_exec calls hit the mediated brokers — net scope via :allow,
  # exec via :exec_allow + :commands. Either way the guest stays sandboxed; the host does the privileged op.
  defp run_built(wasm, stdin, argv, false, _opts), do: run_sandboxed(wasm, stdin, argv)

  defp run_built(wasm, stdin, argv, true, opts) do
    transport_opts =
      [
        allow: Keyword.get(opts, :net_allow),
        principal: Keyword.get(opts, :principal),
        exec_allow: Keyword.get(opts, :exec_allow, false),
        commands: Keyword.get(opts, :commands)
      ]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    case Workbooks.PyNet.run_wasm(wasm, stdin, argv, transport_opts) do
      {:ok, out, _status} -> out
      _ -> ""
    end
  end

  defp run_sandboxed(wasm, stdin, argv) do
    case Workbooks.PackageManager.run(wasm, stdin, argv) do
      out when is_binary(out) -> out
      {out, _status} when is_binary(out) -> out
      _ -> ""
    end
  end

  defp tmp(prefix, ext),
    do: Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}#{ext}")

  defp cap(out, max) when byte_size(out) > max, do: binary_part(out, 0, max)
  defp cap(out, _max), do: out

  defp rate_denied?(principal, {max, window}),
    do: Workbooks.RateLimiter.check(principal, max, window) == {:error, :rate_limited}

  defp deny(why) do
    Workbooks.BrokerAudit.record(:build, :deny)
    require Logger
    Logger.warning("wb-broker: DENY build — #{why}")
  end
end
