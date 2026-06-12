defmodule Workbooks.Pallet do
  @moduledoc """
  Lane A — the prebuilt-WASI command pallet (feasibility-matrix campaign).

  A catalog of sha-PINNED, validated standalone WASI artifacts (real CLIs/runtimes already
  compiled to `wasm32-wasi`) wired into the sandbox through the EXISTING
  `CommandRegistry.fetch_and_register_archive/6` mechanism — pure-Erlang TLS fetch → sha-pin →
  content-address into `build/commands/` → register → run under wasmtime. There is NO per-tool
  engine code here: the lane IS the registry mechanism; each tool is just DATA (name, url, sha,
  the wasm path inside the archive, a default `--dir` preopen, and an arg mode).

  Every entry was PROVED by actually running it under wasmtime (the smoke that verified each is in
  `runtime/.campaign/promote-live.json`). `seed/0` registers them; `seed_one/1` does a single tool.

  Adding a tool = fetch it once, capture its sha256 + the inner `.wasm` path, append a map here.
  The whole `wire-up` cluster lights up through this one path (lanes, not 129 implementations).
  """

  alias Workbooks.CommandRegistry

  # Each entry: name · kind (:wasm single artifact | :archive .tar.gz) · url · sha256 (pinned) ·
  # mode (:argv | :stdin1). :archive entries also carry wasm_rel (path inside the tarball) + preopen
  # ("<subdir>::<guest>" or "." = package root → "/"). Single :wasm entries register via
  # fetch_and_register_wasm; :archive via fetch_and_register_archive.
  @catalog [
    # ── Language runtimes (single-file WASI .wasm) ──────────────────────────────
    %{
      name: "python",
      kind: :wasm,
      url: "https://github.com/vmware-labs/webassembly-language-runtimes/releases/download/python/3.12.0%2B20231211-040d5a6/python-3.12.0.wasm",
      sha: "e5dc5a398b07b54ea8fdb503bf68fb583d533f10ec3f930963e02b9505f7a763",
      mode: :argv
    },
    %{
      name: "ruby",
      kind: :wasm,
      url: "https://github.com/vmware-labs/webassembly-language-runtimes/releases/download/ruby/3.2.2%2B20230714-11be424/ruby-3.2.2-slim.wasm",
      sha: "de598f394e398763d2b147e3e51a6eeadf048128598ac4a3f992a97204c192b0",
      mode: :argv
    },
    %{
      name: "wasm3",
      kind: :wasm,
      url: "https://github.com/wasm3/wasm3/releases/download/v0.5.0/wasm3-wasi.wasm",
      sha: "8427e2f97a14e8c36708fa2c9864f73d1f499305449b5def2cc1b96bfc54a783",
      mode: :argv
    },
    # ── Tools shipped as .tar.gz (wasm + companions) ────────────────────────────
    %{
      name: "coreutils",
      kind: :archive,
      url: "https://github.com/uutils/coreutils/releases/download/0.9.0/coreutils-0.9.0-wasm32-wasip1.tar.gz",
      sha: "e5efa8a1c10bd0ac09eb780d46aff6d8a4ea0be07d41f4dd9a102b266c6eb69f",
      wasm_rel: "coreutils-0.9.0-wasm32-wasip1/coreutils.wasm",
      preopen: ".",
      mode: :argv
    },
    %{
      name: "sqlite3",
      kind: :archive,
      url: "https://cdn.wasmer.io/packages/_/sqlite/sqlite-0.2.2.tar.gz",
      sha: "93d4c1f1b3625c311b431076fe071fa1a111472520fbcffd934fafee5e7cc2ed",
      wasm_rel: "build/sqlite.wasm",
      preopen: ".",
      mode: :argv
    },
    # ── Multi-tool archive (one tarball → many commands, one download) ──────────
    %{
      name: "wabt",
      kind: :archive_many,
      url: "https://github.com/WebAssembly/wabt/releases/download/1.0.41/wabt-1.0.41-wasi.tar.gz",
      sha: "b1f09bde4a7f407d8d2b43b6076004dedf64780cbfcf7cce19207a11ade06f9c",
      mode: :argv,
      entries: [
        {"wat2wasm", "wabt-1.0.41/bin/wat2wasm"},
        {"wasm2wat", "wabt-1.0.41/bin/wasm2wat"},
        {"wasm-validate", "wabt-1.0.41/bin/wasm-validate"},
        {"wasm-decompile", "wabt-1.0.41/bin/wasm-decompile"},
        {"wasm-interp", "wabt-1.0.41/bin/wasm-interp"},
        {"wasm-objdump", "wabt-1.0.41/bin/wasm-objdump"},
        {"wasm-stats", "wabt-1.0.41/bin/wasm-stats"},
        {"wasm-strip", "wabt-1.0.41/bin/wasm-strip"},
        {"wasm2c", "wabt-1.0.41/bin/wasm2c"},
        {"wast2json", "wabt-1.0.41/bin/wast2json"},
        {"wat-desugar", "wabt-1.0.41/bin/wat-desugar"},
        {"spectest-interp", "wabt-1.0.41/bin/spectest-interp"}
      ]
    },
    # ── Tools shipped as .zip (unpacked via Erlang :zip — no native unzip) ───────
    %{
      name: "prolog",
      kind: :zip,
      url: "https://github.com/trealla-prolog/trealla/releases/download/v2.102.25/tpl-wasm-wasi.zip",
      sha: "b31f4bd90336fbfd5b339fb245d4c1c418f8415059c1bfa75eb5fedd02be03d9",
      wasm_rel: "tpl-wasm-wasi/tpl.wasm",
      mode: :argv
    }
  ]

  @doc "The validated pallet catalog (data — each entry sha-pinned + proven under wasmtime)."
  def catalog, do: @catalog

  @doc "Catalog entry names."
  def names, do: Enum.map(@catalog, & &1.name)

  @doc """
  Register every pallet entry (fetch + sha-pin + content-address + register). Returns
  `%{name => :ok | {:error, reason}}`. Idempotent at the registry level — re-seeding replaces the
  binding in place (hot-swap). Network: fetches each artifact once into the content-addressed store.
  """
  def seed, do: Map.new(@catalog, fn e -> {e.name, seed_one(e)} end)

  @doc "Register a single catalog entry by name (or the entry map) → :ok | {:error, reason}."
  def seed_one(name) when is_binary(name) do
    case Enum.find(@catalog, &(&1.name == name)) do
      nil -> {:error, :unknown_pallet_entry}
      e -> seed_one(e)
    end
  end

  def seed_one(%{kind: :wasm, name: n, url: u, sha: s, mode: m}) do
    case CommandRegistry.fetch_and_register_wasm(n, u, s, m) do
      {:ok, _addressed, _sha} -> :ok
      other -> other
    end
  end

  def seed_one(%{kind: :archive, name: n, url: u, sha: s, wasm_rel: w, preopen: p, mode: m}) do
    case CommandRegistry.fetch_and_register_archive(n, u, s, w, p, m) do
      {:ok, _wasm, _sha} -> :ok
      other -> other
    end
  end

  def seed_one(%{kind: :archive_many, url: u, sha: s, entries: es, mode: m}) do
    case CommandRegistry.fetch_and_register_archive_many(u, s, es, m) do
      {:ok, _names} -> :ok
      other -> other
    end
  end

  def seed_one(%{kind: :zip, name: n, url: u, sha: s, wasm_rel: w, mode: m}) do
    case CommandRegistry.fetch_and_register_zip(n, u, s, w, m) do
      {:ok, _wasm, _sha} -> :ok
      other -> other
    end
  end

  # ── Lane B — build-from-source catalog (:csource) ───────────────────────────
  # Real C tools with no prebuilt WASI binary, built IN-SANDBOX (clang.wasm) via the general harvest
  # flow. Each entry is DATA: a sha-pinned source tarball + build_opts (the proven recipe —
  # :src_subdir/:src_globs/:exclude/:extra_sources/:cflags). Building is slow (seconds-to-minutes,
  # content-addressed) so these are NOT auto-seeded at boot like the prebuilt @catalog — `seed_csource/0`
  # builds them ONCE; after that they persist (registry.json) and reload at boot with no rebuild.
  # Adding a harvested tool = append a verified recipe here. No per-tool engine code.

  # A minimal `duk` CLI main (Duktape's bundled cmdline drags in linenoise + a dozen extras): eval
  # `-e CODE` or stdin, print the result via the C API (no print()/console needed).
  @duk_main ~S"""
  #include <stdio.h>
  #include <string.h>
  #include "duktape.h"
  int main(int argc, char **argv) {
    duk_context *ctx = duk_create_heap_default();
    static char buf[1 << 20];
    const char *code = NULL;
    if (argc >= 3 && !strcmp(argv[1], "-e")) code = argv[2];
    else { size_t n = fread(buf, 1, sizeof(buf) - 1, stdin); buf[n] = 0; code = buf; }
    if (duk_peval_string(ctx, code) != 0) fprintf(stderr, "error: %s\n", duk_safe_to_string(ctx, -1));
    else printf("%s\n", duk_safe_to_string(ctx, -1));
    duk_destroy_heap(ctx);
    return 0;
  }
  """

  # A minimal `wren` CLI: eval `-e CODE` or stdin via the Wren embedding API (the bundled cli/ uses
  # libuv for fs/net — not needed for a compute interpreter).
  @wren_main ~S"""
  #include <stdio.h>
  #include <string.h>
  #include "wren.h"
  static void writeFn(WrenVM* vm, const char* text) { (void)vm; fputs(text, stdout); }
  static void errorFn(WrenVM* vm, WrenErrorType t, const char* m, int line, const char* msg) {
    (void)vm; (void)t; fprintf(stderr, "[%s:%d] %s\n", m ? m : "?", line, msg);
  }
  int main(int argc, char** argv) {
    WrenConfiguration c; wrenInitConfiguration(&c); c.writeFn = writeFn; c.errorFn = errorFn;
    WrenVM* vm = wrenNewVM(&c);
    static char buf[1 << 20]; const char* code;
    if (argc >= 3 && !strcmp(argv[1], "-e")) code = argv[2];
    else { size_t n = fread(buf, 1, sizeof(buf) - 1, stdin); buf[n] = 0; code = buf; }
    wrenInterpret(vm, "main", code);
    wrenFreeVM(vm); return 0;
  }
  """

  # A minimal `qjs` CLI: eval `-e CODE` or stdin via the QuickJS embedding API (skips qjs.c, which
  # needs a qjsc-generated repl.c, and quickjs-libc.c's std/os modules — pure-compute eval).
  @qjs_main ~S"""
  #include <stdio.h>
  #include <string.h>
  #include "quickjs.h"
  int main(int argc, char** argv) {
    JSRuntime* rt = JS_NewRuntime(); JSContext* ctx = JS_NewContext(rt);
    static char buf[1 << 20]; const char* code;
    if (argc >= 3 && !strcmp(argv[1], "-e")) code = argv[2];
    else { size_t n = fread(buf, 1, sizeof(buf) - 1, stdin); buf[n] = 0; code = buf; }
    JSValue v = JS_Eval(ctx, code, strlen(code), "<eval>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(v)) { JSValue e = JS_GetException(ctx); const char* s = JS_ToCString(ctx, e); fprintf(stderr, "error: %s\n", s ? s : "?"); }
    else { const char* s = JS_ToCString(ctx, v); printf("%s\n", s ? s : "undefined"); }
    JS_FreeContext(ctx); JS_FreeRuntime(rt); return 0;
  }
  """

  # A minimal gzip-compatible `gz` CLI on zlib's stream API (windowBits 15+16 = gzip wrapper, so the
  # output interops with gzip/gunzip). stdin → compressed stdout; `-d` decompresses. The gz* FILE-API
  # files (gzlib/gzread/gzwrite/gzclose, which use lseek) are excluded — not needed for streaming.
  @gz_main ~S"""
  #include <stdio.h>
  #include <stdlib.h>
  #include <string.h>
  #include "zlib.h"
  int main(int argc, char** argv) {
    int dec = (argc >= 2 && !strcmp(argv[1], "-d"));
    size_t cap = 1 << 20, len = 0; unsigned char* in = malloc(cap); size_t r;
    while ((r = fread(in + len, 1, cap - len, stdin)) > 0) { len += r; if (len == cap) { cap *= 2; in = realloc(in, cap); } }
    z_stream s; memset(&s, 0, sizeof(s));
    size_t ocap = len * 2 + 1024; unsigned char* out = malloc(ocap);
    if (dec) {
      inflateInit2(&s, 15 + 16); s.next_in = in; s.avail_in = len; s.next_out = out; s.avail_out = ocap; int ret;
      do { if (s.avail_out == 0) { size_t u = s.next_out - out; ocap *= 2; out = realloc(out, ocap); s.next_out = out + u; s.avail_out = ocap - u; } ret = inflate(&s, Z_FINISH); } while (ret == Z_OK || ret == Z_BUF_ERROR);
      fwrite(out, 1, s.next_out - out, stdout); inflateEnd(&s);
    } else {
      deflateInit2(&s, 6, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY); s.next_in = in; s.avail_in = len; s.next_out = out; s.avail_out = ocap;
      deflate(&s, Z_FINISH); fwrite(out, 1, s.next_out - out, stdout); deflateEnd(&s);
    }
    return 0;
  }
  """

  # A minimal `lz4` CLI on the LZ4 frame API (standard .lz4 format): stdin → compressed stdout, `-d`
  # decompresses. Interoperates with the lz4 tool. (lz4's lib is a unity build — needs preserve_names.)
  @lz4_main ~S"""
  #include <stdio.h>
  #include <stdlib.h>
  #include <string.h>
  #include "lz4frame.h"
  int main(int argc, char** argv) {
    int dec = (argc >= 2 && !strcmp(argv[1], "-d"));
    size_t cap = 1 << 20, len = 0; char* in = malloc(cap); size_t r;
    while ((r = fread(in + len, 1, cap - len, stdin)) > 0) { len += r; if (len == cap) { cap *= 2; in = realloc(in, cap); } }
    if (dec) {
      LZ4F_dctx* d; LZ4F_createDecompressionContext(&d, LZ4F_VERSION);
      size_t ocap = 1 << 20; char* out = malloc(ocap); size_t sp = 0;
      while (sp < len) { size_t ds = ocap, ss = len - sp; LZ4F_decompress(d, out, &ds, in + sp, &ss, NULL); fwrite(out, 1, ds, stdout); sp += ss; if (ss == 0) break; }
      LZ4F_freeDecompressionContext(d);
    } else {
      size_t b = LZ4F_compressFrameBound(len, NULL); char* out = malloc(b);
      size_t n = LZ4F_compressFrame(out, b, in, len, NULL); fwrite(out, 1, n, stdout);
    }
    return 0;
  }
  """

  # A minimal `b2` CLI: BLAKE2b-512 of stdin → hex (Monocypher's modern crypto core).
  @b2_main ~S"""
  #include <stdio.h>
  #include <stdlib.h>
  #include "monocypher.h"
  int main(void) {
    size_t cap = 1 << 20, len = 0; unsigned char* in = malloc(cap); size_t r;
    while ((r = fread(in + len, 1, cap - len, stdin)) > 0) { len += r; if (len == cap) { cap *= 2; in = realloc(in, cap); } }
    unsigned char h[64];
    crypto_blake2b(h, 64, in, len);
    for (int i = 0; i < 64; i++) printf("%02x", h[i]);
    printf("\n");
    return 0;
  }
  """

  # A minimal `md` CLI: CommonMark markdown on stdin → HTML on stdout (md4c).
  @md_main ~S"""
  #include <stdio.h>
  #include <stdlib.h>
  #include "md4c-html.h"
  static void out(const MD_CHAR* t, MD_SIZE n, void* ud) { (void)ud; fwrite(t, 1, n, stdout); }
  int main(void) {
    size_t cap = 1 << 20, len = 0; char* in = malloc(cap); size_t r;
    while ((r = fread(in + len, 1, cap - len, stdin)) > 0) { len += r; if (len == cap) { cap *= 2; in = realloc(in, cap); } }
    md_html(in, (MD_SIZE)len, out, NULL, 0, 0);
    return 0;
  }
  """

  # A minimal `zstd` CLI on the zstd simple API (standard .zst frame): stdin → compressed stdout, `-d`
  # decompresses. Interoperates with the zstd tool.
  @zstd_main ~S"""
  #include <stdio.h>
  #include <stdlib.h>
  #include <string.h>
  #include "zstd.h"
  int main(int argc, char** argv) {
    int dec = (argc >= 2 && !strcmp(argv[1], "-d"));
    size_t cap = 1 << 20, len = 0; char* in = malloc(cap); size_t r;
    while ((r = fread(in + len, 1, cap - len, stdin)) > 0) { len += r; if (len == cap) { cap *= 2; in = realloc(in, cap); } }
    if (dec) {
      unsigned long long os = ZSTD_getFrameContentSize(in, len);
      size_t oc = (os > 0 && os < (1ULL << 40)) ? os : len * 30 + 1024; char* out = malloc(oc);
      size_t n = ZSTD_decompress(out, oc, in, len);
      if (!ZSTD_isError(n)) fwrite(out, 1, n, stdout); else fprintf(stderr, "err: %s\n", ZSTD_getErrorName(n));
    } else {
      size_t b = ZSTD_compressBound(len); char* out = malloc(b);
      size_t n = ZSTD_compress(out, b, in, len, 3);
      if (!ZSTD_isError(n)) fwrite(out, 1, n, stdout); else fprintf(stderr, "err: %s\n", ZSTD_getErrorName(n));
    }
    return 0;
  }
  """

  # A minimal `qr` CLI: stdin text → an ASCII QR code (nayuki qrcodegen, ## = dark module).
  @qr_main ~S"""
  #include <stdio.h>
  #include <string.h>
  #include "qrcodegen.h"
  int main(void) {
    static char buf[8192]; size_t n = fread(buf, 1, sizeof(buf) - 1, stdin); buf[n] = 0;
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) buf[--n] = 0;
    uint8_t qr[qrcodegen_BUFFER_LEN_MAX], tmp[qrcodegen_BUFFER_LEN_MAX];
    if (!qrcodegen_encodeText(buf, tmp, qr, qrcodegen_Ecc_MEDIUM, qrcodegen_VERSION_MIN, qrcodegen_VERSION_MAX, qrcodegen_Mask_AUTO, true)) { fprintf(stderr, "qr: encode failed\n"); return 1; }
    int s = qrcodegen_getSize(qr);
    for (int y = -1; y <= s; y++) { for (int x = -1; x <= s; x++) { int d = (x >= 0 && x < s && y >= 0 && y < s) && qrcodegen_getModule(qr, x, y); fputs(d ? "##" : "  ", stdout); } putchar('\n'); }
    return 0;
  }
  """

  @csource [
    %{
      name: "lua",
      url: "https://www.lua.org/ftp/lua-5.4.7.tar.gz",
      sha: "9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30",
      build_opts: [src_subdir: "src", exclude: ["luac.c"]]
    },
    %{
      name: "duk",
      url: "https://duktape.org/duktape-2.7.0.tar.xz",
      sha: "90f8d2fa8b5567c6899830ddef2c03f3c27960b11aca222fa17aa7ac613c2890",
      build_opts: [src_globs: ["src/*.{c,h}"], extra_sources: [{"duk_main.c", @duk_main}]]
    },
    %{
      name: "wren",
      url: "https://codeload.github.com/wren-lang/wren/tar.gz/refs/tags/0.4.0",
      sha: "23c0ddeb6c67a4ed9285bded49f7c91714922c2e7bb88f42428386bf1cf7b339",
      build_opts: [
        src_globs: ["src/include/*", "src/vm/*", "src/optional/*"],
        extra_sources: [{"wren_main.c", @wren_main}]
      ]
    },
    %{
      name: "qjs",
      url: "https://codeload.github.com/quickjs-ng/quickjs/tar.gz/refs/tags/v0.10.0",
      sha: "c54007e6ce9893b0074d53feac47c64a362900df20493110800c9e1f5c43427b",
      build_opts: [
        src_globs: ["*.{c,h}"],
        exclude: ~w(qjs.c qjsc.c quickjs-libc.c api-test.c ctest.c fuzz.c run-test262.c unicode_gen.c),
        extra_sources: [{"qjs_main.c", @qjs_main}]
      ]
    },
    %{
      name: "gz",
      url: "https://codeload.github.com/madler/zlib/tar.gz/refs/tags/v1.3.1",
      sha: "17e88863f3600672ab49182f217281b6fc4d3c762bde361935e436a95214d05c",
      build_opts: [
        src_globs: ["*.{c,h}"],
        exclude: ~w(gzlib.c gzread.c gzwrite.c gzclose.c),
        extra_sources: [{"zmain.c", @gz_main}]
      ]
    },
    %{
      name: "lz4",
      url: "https://codeload.github.com/lz4/lz4/tar.gz/refs/tags/v1.10.0",
      sha: "537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b",
      build_opts: [src_globs: ["lib/*.{c,h}"], exclude: ["lz4file.c"], extra_sources: [{"lz4_main.c", @lz4_main}]]
    },
    %{
      name: "b2",
      url: "https://monocypher.org/download/monocypher-4.0.2.tar.gz",
      sha: "38d07179738c0c90677dba3ceb7a7b8496bcfea758ba1a53e803fed30ae0879c",
      build_opts: [src_globs: ["src/monocypher.{c,h}"], extra_sources: [{"b2main.c", @b2_main}]]
    },
    %{
      name: "md",
      url: "https://codeload.github.com/mity/md4c/tar.gz/refs/tags/release-0.5.2",
      sha: "55d0111d48fb11883aaee91465e642b8b640775a4d6993c2d0e7a8092758ef21",
      build_opts: [src_globs: ["src/*.{c,h}"], extra_sources: [{"md_main.c", @md_main}]]
    },
    %{
      name: "zstd",
      url: "https://github.com/facebook/zstd/releases/download/v1.5.6/zstd-1.5.6.tar.gz",
      sha: "8c29e06cf42aacc1eafc4077ae2ec6c6fcb96a626157e0593d5e82a34fd403c1",
      build_opts: [
        src_globs: ["lib/*.h", "lib/common/*.{c,h}", "lib/compress/*.{c,h}", "lib/decompress/*.{c,h}"],
        extra_sources: [{"zmain.c", @zstd_main}],
        cflags: ["-DZSTD_DISABLE_ASM=1"]
      ]
    },
    %{
      name: "qr",
      url: "https://codeload.github.com/nayuki/QR-Code-generator/tar.gz/refs/tags/v1.8.0",
      sha: "2ec0a4d33d6f521c942eeaf473d42d5fe139abcfa57d2beffe10c5cf7d34ae60",
      build_opts: [
        src_globs: ["c/*.{c,h}"],
        exclude: ~w(qrcodegen-demo.c qrcodegen-test.c),
        extra_sources: [{"qrmain.c", @qr_main}]
      ]
    }
  ]

  @doc "The build-from-source catalog (data — sha-pinned source tarballs + proven build recipes)."
  def csource_catalog, do: @csource

  @doc """
  Build + register every :csource tool in-sandbox (SLOW — one clang.wasm build each; one-time, then
  persisted + reloaded at boot). Returns `%{name => :ok | {:error, reason}}`. Call once to provision.
  """
  def seed_csource, do: Map.new(@csource, fn e -> {e.name, seed_csource_one(e)} end)

  @doc "Build + register one :csource entry by name (or the entry map)."
  def seed_csource_one(name) when is_binary(name) do
    case Enum.find(@csource, &(&1.name == name)) do
      nil -> {:error, :unknown_csource_entry}
      e -> seed_csource_one(e)
    end
  end

  def seed_csource_one(%{name: n, url: u, sha: s, build_opts: opts}) do
    # Already registered (e.g. reloaded from the persisted cache at boot)? Skip the rebuild — makes
    # seed_csource idempotent + cheap on every boot after the first.
    if n in CommandRegistry.list() do
      :ok
    else
      case CommandRegistry.build_and_register_c_source(n, u, s, opts) do
        {:ok, _addressed} -> :ok
        other -> other
      end
    end
  end
end
