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
      # PHP (Zend) as the php-cgi SAPI. File-mode: run a script via `run("php", "", ["-f","/w/x.php"], ["host::/w"])`.
      name: "php",
      kind: :wasm,
      url: "https://github.com/vmware-labs/webassembly-language-runtimes/releases/download/php/8.2.6%2B20230714-11be424/php-cgi-8.2.6.wasm",
      sha: "edb29de7cd80597292670499846db56929af1166459c4a776ef606aef357c93b",
      mode: :argv
    },
    %{
      # openssl — the full OpenSSL CLI (dgst/enc/genrsa/x509/rand/…), prebuilt wasm32-wasi (voltbuilder),
      # WASI-only imports. `openssl version` / `openssl dgst -sha256` on stdin.
      name: "openssl",
      kind: :wasm,
      url: "https://github.com/voltbuilder/openssl-wasm/releases/download/v1.1.1o/openssl.wasm",
      sha: "ad236c86d94687005e11ac14a1f6a7c2fac246b0297bc09e299808eb13a8e8dc",
      mode: :argv
    },
    %{
      # Agda — dependently-typed language / proof assistant, prebuilt wasm32-wasi (GHC 9.10 wasm backend).
      # Zip ships opt/agda-opt.wasm (wasm-opt'd, 31MB) + opt/lib/prim datadir. `--version` runs standalone;
      # batch typecheck (agda file.agda) needs the prim datadir mounted (--dir + Agda_datadir) — follow-up.
      name: "agda",
      kind: :zip,
      url: "https://github.com/agda-web/agda-wasm-dist/releases/download/v2.8.0-ghc9.10.3-r0/agda-wasm-v2.8.0-ghc9.10.3-r0.zip",
      sha: "1aa2fb20e8c78bfb0ee1baf24be9517b61ad2f7e45c5c196df72a09f60d981d4",
      wasm_rel: "opt/agda-opt.wasm",
      mode: :argv
    },
    %{
      # pandoc — universal document converter (markdown/HTML/LaTeX/RST/docx/…), prebuilt wasm32-wasi
      # (GHC 9.12 wasm backend, no JS host). 53MB, fetched at seed. `pandoc -f <from> -t <to>` stdin→stdout.
      name: "pandoc",
      kind: :wasm,
      url: "https://haskell-wasm.github.io/pandoc-wasm/pandoc.wasm",
      sha: "48d9ceed3ef805f6acc28e6f58c2439cdeb1f71864244fffcc155e2c045aa7fc",
      mode: :argv
    },
    %{
      # libjpeg-turbo CLI tools (prebuilt WASI, vmware WLR). cjpeg/djpeg: PPM<->JPEG on stdin/stdout.
      name: "jpeg",
      kind: :archive_many,
      url: "https://github.com/vmware-labs/webassembly-language-runtimes/releases/download/libs/libjpeg/2.1.5.1%2B20230623-2993864/jpeg-bin-2.1.5.1-wasi-sdk-20.0.tar.gz",
      sha: "9809568fb042cd6d8961fec1a23b86a66ec0f421f69f3182a0986030769c372d",
      mode: :argv,
      entries: [{"cjpeg", "bin/cjpeg"}, {"djpeg", "bin/djpeg"}, {"jpegtran", "bin/jpegtran"}]
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

  # A minimal `b3` CLI: BLAKE3-256 of stdin → hex (the modern fast crypto hash).
  @b3_main ~S"""
  #include <stdio.h>
  #include <stdlib.h>
  #include "blake3.h"
  int main(void) {
    blake3_hasher h; blake3_hasher_init(&h);
    static unsigned char buf[65536]; size_t r;
    while ((r = fread(buf, 1, sizeof(buf), stdin)) > 0) blake3_hasher_update(&h, buf, r);
    unsigned char out[BLAKE3_OUT_LEN];
    blake3_hasher_finalize(&h, out, BLAKE3_OUT_LEN);
    for (int i = 0; i < BLAKE3_OUT_LEN; i++) printf("%02x", out[i]);
    printf("\n");
    return 0;
  }
  """

  # A minimal `br` CLI: brotli web compression — stdin → compressed stdout, `-d` decompresses.
  @br_main ~S"""
  #include <stdio.h>
  #include <stdlib.h>
  #include <string.h>
  #include "brotli/encode.h"
  #include "brotli/decode.h"
  int main(int argc, char** argv) {
    int dec = (argc >= 2 && !strcmp(argv[1], "-d"));
    size_t cap = 1 << 20, len = 0; uint8_t* in = malloc(cap); size_t r;
    while ((r = fread(in + len, 1, cap - len, stdin)) > 0) { len += r; if (len == cap) { cap *= 2; in = realloc(in, cap); } }
    if (dec) {
      size_t oc = len * 30 + 1024; uint8_t* out = malloc(oc); size_t os = oc;
      if (BrotliDecoderDecompress(len, in, &os, out) == BROTLI_DECODER_RESULT_SUCCESS) fwrite(out, 1, os, stdout); else fprintf(stderr, "br: decode failed\n");
    } else {
      size_t oc = BrotliEncoderMaxCompressedSize(len); uint8_t* out = malloc(oc); size_t os = oc;
      if (BrotliEncoderCompress(BROTLI_DEFAULT_QUALITY, BROTLI_DEFAULT_WINDOW, BROTLI_MODE_GENERIC, len, in, &os, out)) fwrite(out, 1, os, stdout); else fprintf(stderr, "br: encode failed\n");
    }
    return 0;
  }
  """

  # A minimal `argon2` CLI: Argon2id password hash of stdin → hex (Monocypher; fixed salt + params
  # for a deterministic demo hasher — real use would random-salt per password).
  @argon2_main ~S"""
  #include <stdio.h>
  #include <stdlib.h>
  #include <string.h>
  #include "monocypher.h"
  int main(void) {
    static char pw[4096]; size_t n = fread(pw, 1, sizeof(pw) - 1, stdin); pw[n] = 0;
    while (n > 0 && (pw[n - 1] == '\n' || pw[n - 1] == '\r')) pw[--n] = 0;
    uint8_t salt[16]; memcpy(salt, "wb-fixed-salt-16", 16);
    uint32_t nb_blocks = 1024; void* work = malloc((size_t)nb_blocks * 1024);
    uint8_t hash[32];
    crypto_argon2_config cfg = { CRYPTO_ARGON2_ID, nb_blocks, 3, 1 };
    crypto_argon2_inputs inp = { (const uint8_t*)pw, salt, (uint32_t)n, sizeof(salt) };
    crypto_argon2(hash, sizeof(hash), work, cfg, inp, crypto_argon2_no_extras);
    for (int i = 0; i < 32; i++) printf("%02x", hash[i]);
    printf("\n"); free(work); return 0;
  }
  """

  # `mujs`: Artifex MuJS — a small ES5 JavaScript interpreter (distinct from qjs/duk). Minimal eval main.
  @mujs_main ~S"""
  #include <stdio.h>
  #include <stdlib.h>
  #include "mujs.h"
  static void jsprint(js_State *J) { const char* s = js_tostring(J, 1); fputs(s, stdout); fputc('\n', stdout); js_pushundefined(J); }
  int main(void) {
    static char buf[1 << 16]; size_t n = fread(buf, 1, sizeof(buf) - 1, stdin); buf[n] = 0;
    js_State *J = js_newstate(NULL, NULL, JS_STRICT);
    js_newcfunction(J, jsprint, "print", 1); js_setglobal(J, "print");
    if (js_dostring(J, buf)) fprintf(stderr, "mujs: error\n");
    js_freestate(J);
    return 0;
  }
  """

  # zForth (Forth): tiny C interpreter (ctx-based API) + its forth bootstrap (core.zf, embedded at
  # compile time so the command is self-contained — core.zf defines `.`/emit/`:`/`;` etc.). setjmp →
  # rides the lane's SJLJ path.
  @zforth_core File.read!(Path.join(__DIR__, "../priv/zforth/core_zf.h"))
  @zforth_main ~S"""
  #include <stdio.h>
  #include <stdlib.h>
  #include <stdarg.h>
  #include "zforth.h"
  #include "core_zf.h"
  zf_input_state zf_host_sys(zf_ctx *ctx, zf_syscall_id id, const char *last_word) {
    (void)last_word;
    switch ((int)id) {
      case ZF_SYSCALL_EMIT: putchar((int)zf_pop(ctx)); break;
      case ZF_SYSCALL_PRINT: printf(ZF_CELL_FMT " ", zf_pop(ctx)); break;
      case ZF_SYSCALL_TELL: { zf_cell len = zf_pop(ctx); zf_cell addr = zf_pop(ctx); const char* p = (const char*)zf_dump(ctx, NULL) + (int)addr; fwrite(p, 1, (size_t)len, stdout); break; }
      default: break;
    }
    return ZF_INPUT_INTERPRET;
  }
  void zf_host_trace(zf_ctx *ctx, const char *fmt, va_list va) { (void)ctx; vfprintf(stderr, fmt, va); }
  zf_cell zf_host_parse_num(zf_ctx *ctx, const char *buf) { char *e; zf_cell v = strtol(buf, &e, 0); if (*e) zf_abort(ctx, ZF_ABORT_NOT_A_WORD); return v; }
  int main(void) {
    static zf_ctx ctx;
    zf_init(&ctx, 0); zf_bootstrap(&ctx);
    zf_eval(&ctx, CORE_ZF);
    static char l[4096]; while (fgets(l, sizeof(l), stdin)) zf_eval(&ctx, l);
    return 0;
  }
  """

  # `tar`: list/extract a tar archive (microtar, single-file). `tar t|x <file.tar>` with a --dir mount.
  @tar_main ~S"""
  #include <stdio.h>
  #include <stdlib.h>
  #include <string.h>
  #include "microtar.h"
  int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "usage: tar t|x <file.tar>\n"); return 1; }
    char mode = argv[1][0];
    mtar_t tar; mtar_header_t h;
    if (mtar_open(&tar, argv[2], "r") != MTAR_ESUCCESS) { fprintf(stderr, "tar: open fail\n"); return 1; }
    while (mtar_read_header(&tar, &h) == MTAR_ESUCCESS) {
      if (mode == 't') printf("%s\n", h.name);
      else if (mode == 'x') { char* b = malloc(h.size); mtar_read_data(&tar, b, h.size); FILE* f = fopen(h.name, "wb"); if (f) { fwrite(b, 1, h.size, f); fclose(f); } free(b); }
      mtar_next(&tar);
    }
    mtar_close(&tar); return 0;
  }
  """

  # PCRE2 (Perl-compatible regex). Ships pre-generated headers (config.h.generic / pcre2.h.generic /
  # pcre2_chartables.c.dist) so NO ./configure is needed — committed as fixtures + read at compile time,
  # injected as config.h / pcre2.h / pcre2_chartables.c (with -I/work so src/*.c find them).
  @pcre2_config File.read!(Path.join(__DIR__, "../priv/pcre2/config.h"))
  @pcre2_h File.read!(Path.join(__DIR__, "../priv/pcre2/pcre2.h"))
  @pcre2_tables File.read!(Path.join(__DIR__, "../priv/pcre2/pcre2_chartables.c"))
  @pcre2_main ~S"""
  #define PCRE2_CODE_UNIT_WIDTH 8
  #include <stdio.h>
  #include <stdlib.h>
  #include <string.h>
  #include "pcre2.h"
  int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: pcre2 <pattern>\n"); return 1; }
    int err; PCRE2_SIZE eoff;
    pcre2_code *re = pcre2_compile((PCRE2_SPTR)argv[1], PCRE2_ZERO_TERMINATED, 0, &err, &eoff, NULL);
    if (!re) { fprintf(stderr, "bad pattern\n"); return 1; }
    pcre2_match_data *md = pcre2_match_data_create_from_pattern(re, NULL);
    char line[8192];
    while (fgets(line, sizeof(line), stdin)) {
      size_t len = strlen(line); if (len && line[len - 1] == '\n') line[--len] = 0;
      if (pcre2_match(re, (PCRE2_SPTR)line, len, 0, 0, md, NULL) >= 0) printf("%s\n", line);
    }
    return 0;
  }
  """

  # libsodium (NaCl crypto). version.h is configure-generated (not shipped) — inject it at its nested
  # path. `sodium` = BLAKE2b (crypto_generichash) of stdin → hex (proves the whole lib links + runs).
  @sodium_version ~S"""
  #ifndef sodium_version_H
  #define sodium_version_H
  #include "export.h"
  #define SODIUM_VERSION_STRING "1.0.20"
  #define SODIUM_LIBRARY_VERSION_MAJOR 26
  #define SODIUM_LIBRARY_VERSION_MINOR 2
  #ifdef __cplusplus
  extern "C" {
  #endif
  SODIUM_EXPORT const char *sodium_version_string(void);
  SODIUM_EXPORT int sodium_library_version_major(void);
  SODIUM_EXPORT int sodium_library_version_minor(void);
  SODIUM_EXPORT int sodium_library_minimal(void);
  #ifdef __cplusplus
  }
  #endif
  #endif
  """
  @sodium_main ~S"""
  #include <stdio.h>
  #include <sodium.h>
  int main(void) {
    if (sodium_init() < 0) return 1;
    static unsigned char buf[65536];
    crypto_generichash_state st; crypto_generichash_init(&st, NULL, 0, 32);
    size_t n; while ((n = fread(buf, 1, sizeof buf, stdin)) > 0) crypto_generichash_update(&st, buf, n);
    unsigned char h[32]; crypto_generichash_final(&st, h, 32);
    for (int i = 0; i < 32; i++) printf("%02x", h[i]);
    printf("\n");
    return 0;
  }
  """

  # `wuffs`: CRC32/IEEE of stdin → hex (Wuffs — Google's memory-safe codec lib). The driver #includes the
  # single-file amalgamation wuffs-v0.3.c, which is :include_only (present, not compiled standalone).
  @wuffs_driver ~S"""
  #define WUFFS_IMPLEMENTATION
  #define WUFFS_CONFIG__MODULES
  #define WUFFS_CONFIG__MODULE__BASE
  #define WUFFS_CONFIG__MODULE__CRC32
  #include "wuffs-v0.3.c"
  #include <stdio.h>
  int main(void) {
    wuffs_crc32__ieee_hasher h;
    wuffs_crc32__ieee_hasher__initialize(&h, sizeof(h), WUFFS_VERSION, 0);
    unsigned char buf[65536]; size_t n; uint32_t crc = 0;
    while ((n = fread(buf, 1, sizeof buf, stdin)) > 0) crc = wuffs_crc32__ieee_hasher__update_u32(&h, wuffs_base__make_slice_u8(buf, n));
    printf("%08x\n", crc);
    return 0;
  }
  """

  # FreeType (font engine). Built from its umbrella TUs (:compile_only — each #includes its parts) with
  # a trimmed ftmodule.h (only the modules we compile) so ftinit doesn't reference uncompiled drivers.
  @freetype_ftmodule ~S"""
  FT_USE_MODULE( FT_Module_Class, autofit_module_class )
  FT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )
  FT_USE_MODULE( FT_Driver_ClassRec, t1_driver_class )
  FT_USE_MODULE( FT_Driver_ClassRec, cff_driver_class )
  FT_USE_MODULE( FT_Driver_ClassRec, t1cid_driver_class )
  FT_USE_MODULE( FT_Module_Class, psaux_module_class )
  FT_USE_MODULE( FT_Module_Class, psnames_module_class )
  FT_USE_MODULE( FT_Module_Class, pshinter_module_class )
  FT_USE_MODULE( FT_Module_Class, sfnt_module_class )
  FT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )
  FT_USE_MODULE( FT_Renderer_Class, ft_raster1_renderer_class )
  FT_USE_MODULE( FT_Renderer_Class, ft_sdf_renderer_class )
  FT_USE_MODULE( FT_Renderer_Class, ft_bitmap_sdf_renderer_class )
  """
  @freetype_main ~S"""
  #include <stdio.h>
  #include <ft2build.h>
  #include FT_FREETYPE_H
  int main(void) {
    FT_Library lib;
    if (FT_Init_FreeType(&lib)) { puts("init-fail"); return 1; }
    FT_Int maj, min, pat; FT_Library_Version(lib, &maj, &min, &pat);
    printf("freetype %d.%d.%d\n", maj, min, pat);
    FT_Done_FreeType(lib); return 0;
  }
  """
  @freetype_umbrellas ~w(ftsystem.c ftinit.c ftdebug.c ftbase.c ftbbox.c ftglyph.c ftbitmap.c ftmm.c
                         ftstroke.c ftsynth.c sfnt.c truetype.c cff.c type1.c type1cid.c autofit.c
                         smooth.c raster.c sdf.c psaux.c pshinter.c psnames.c ftgzip.c ftmain.c)

  # HarfBuzz (text shaping) — C++ amalgam: src/harfbuzz.cc #includes all the parts (:compile_only).
  @harfbuzz_main ~S"""
  #include <stdio.h>
  #include "hb.h"
  int main(void) { printf("harfbuzz %s\n", hb_version_string()); return 0; }
  """

  # mbedTLS — replace its default config with a minimal crypto-only one (MBEDTLS_CONFIG_FILE) so the build
  # doesn't drag in net/entropy/PSA cascades; `mbedtls` = SHA-256 of stdin → hex.
  @mbedtls_config ~S"""
  #ifndef MBEDTLS_MIN_CONFIG_H
  #define MBEDTLS_MIN_CONFIG_H
  #define MBEDTLS_SHA256_C
  #define MBEDTLS_SHA224_C
  #define MBEDTLS_AES_C
  #endif
  """
  @mbedtls_main ~S"""
  #include <stdio.h>
  #include "mbedtls/sha256.h"
  int main(void) {
    mbedtls_sha256_context ctx; mbedtls_sha256_init(&ctx); mbedtls_sha256_starts(&ctx, 0);
    unsigned char buf[65536]; size_t n;
    while ((n = fread(buf, 1, sizeof buf, stdin)) > 0) mbedtls_sha256_update(&ctx, buf, n);
    unsigned char h[32]; mbedtls_sha256_finish(&ctx, h);
    for (int i = 0; i < 32; i++) printf("%02x", h[i]);
    printf("\n");
    return 0;
  }
  """

  # expat (XML parser). Provide a wasi expat_config.h (getentropy) overriding the macOS one; compile only
  # the getentropy random backend; xmltok_impl/ns are :include_only (xmltok.c #includes them). `expat`
  # counts elements in stdin XML (proves well-formed parse).
  @expat_config ~S"""
  #ifndef EXPAT_CONFIG_H
  #define EXPAT_CONFIG_H
  #define XML_DTD 1
  #define XML_GE 1
  #define XML_NS 1
  #define XML_CONTEXT_BYTES 1024
  #define HAVE_GETENTROPY 1
  #define HAVE_STDINT_H 1
  #define HAVE_STDLIB_H 1
  #define HAVE_STRING_H 1
  #define HAVE_MEMORY_H 1
  #define BYTEORDER 1234
  #define PACKAGE_VERSION "2.8.1"
  #endif
  """
  @expat_main ~S"""
  #include <stdio.h>
  #include "expat.h"
  static int elems = 0;
  static void start(void *u, const char *name, const char **atts) { (void)u; (void)name; (void)atts; elems++; }
  int main(void) {
    XML_Parser p = XML_ParserCreate(NULL);
    XML_SetStartElementHandler(p, start);
    static char buf[1 << 16]; size_t n = fread(buf, 1, sizeof buf, stdin);
    if (XML_Parse(p, buf, (int)n, 1) == XML_STATUS_ERROR) { printf("error\n"); return 1; }
    printf("%d\n", elems);
    XML_ParserFree(p);
    return 0;
  }
  """

  # Oniguruma (regex engine — Ruby/PHP's). Provide a wasm32 config.h (regenc.h includes it
  # unconditionally); the unicode *_data.c are #included by unicode.c (:include_only). `onig` = grep.
  @onig_config ~S"""
  #define HAVE_STDARG_H 1
  #define HAVE_STDLIB_H 1
  #define HAVE_STRING_H 1
  #define HAVE_STRINGS_H 1
  #define HAVE_INTTYPES_H 1
  #define HAVE_STDINT_H 1
  #define SIZEOF_INT 4
  #define SIZEOF_LONG 4
  #define SIZEOF_LONG_LONG 8
  #define SIZEOF_VOIDP 4
  #define HAVE_PROTOTYPES 1
  #define HAVE_STDARG_PROTOTYPES 1
  """
  @onig_main ~S"""
  #include <stdio.h>
  #include <string.h>
  #include "oniguruma.h"
  int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: onig <pattern>\n"); return 1; }
    OnigErrorInfo einfo; regex_t* reg;
    UChar* pat = (UChar*)argv[1];
    if (onig_new(&reg, pat, pat + strlen(argv[1]), ONIG_OPTION_DEFAULT, ONIG_ENCODING_UTF8, ONIG_SYNTAX_DEFAULT, &einfo) != ONIG_NORMAL) { fprintf(stderr, "bad pattern\n"); return 1; }
    OnigRegion* region = onig_region_new();
    char line[8192];
    while (fgets(line, sizeof(line), stdin)) {
      size_t len = strlen(line); if (len && line[len - 1] == '\n') line[--len] = 0;
      UChar* s = (UChar*)line;
      if (onig_search(reg, s, s + len, s, s + len, region, ONIG_OPTION_NONE) >= 0) printf("%s\n", line);
    }
    onig_region_free(region, 1); onig_free(reg); onig_end();
    return 0;
  }
  """

  # libxml2 — full XML (XPath/DOM/validation, richer than expat's SAX). configure-generated headers are
  # hand-substituted: config.h (HAVE_*) inline + xmlversion.h (feature matrix: core on, network/iconv/zlib/
  # threads off) vendored. -Wno-implicit-function-declaration + the global dup() stub cover wasi-libc's
  # missing dup (wb-u1ly). `xml2 <xpath>` evaluates an XPath over stdin XML.
  @libxml2_config ~S"""
  #define HAVE_STDLIB_H 1
  #define HAVE_STRING_H 1
  #define HAVE_UNISTD_H 1
  #define HAVE_FCNTL_H 1
  #define HAVE_SYS_STAT_H 1
  #define HAVE_SYS_TYPES_H 1
  #define HAVE_STDINT_H 1
  #define HAVE_INTTYPES_H 1
  #define HAVE_MATH_H 1
  #define HAVE_FLOAT_H 1
  #define HAVE_LIMITS_H 1
  #define HAVE_TIME_H 1
  #define HAVE_ERRNO_H 1
  #define HAVE_CTYPE_H 1
  #define HAVE_ISNAN 1
  #define HAVE_ISINF 1
  #define VERSION "2.13.5"
  """
  @libxml2_xmlversion File.read!(Path.join(__DIR__, "../priv/libxml2/xmlversion.h"))
  @libxml2_main ~S"""
  #include <stdio.h>
  #include <string.h>
  #include <libxml/parser.h>
  #include <libxml/xpath.h>
  int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: xml2 <xpath>\n"); return 1; }
    static char buf[1 << 20]; size_t n = fread(buf, 1, sizeof buf, stdin);
    xmlDocPtr doc = xmlReadMemory(buf, (int)n, "in.xml", NULL, 0);
    if (!doc) { printf("parse-error\n"); return 1; }
    xmlXPathContextPtr ctx = xmlXPathNewContext(doc);
    xmlXPathObjectPtr r = xmlXPathEvalExpression((const xmlChar*)argv[1], ctx);
    if (!r) { printf("xpath-error\n"); return 1; }
    switch (r->type) {
      case XPATH_NUMBER: printf("%g\n", r->floatval); break;
      case XPATH_BOOLEAN: printf("%s\n", r->boolval ? "true" : "false"); break;
      case XPATH_STRING: printf("%s\n", (char*)r->stringval); break;
      case XPATH_NODESET:
        if (r->nodesetval)
          for (int i = 0; i < r->nodesetval->nodeNr; i++) {
            xmlChar* c = xmlNodeGetContent(r->nodesetval->nodeTab[i]);
            printf("%s\n", (char*)c); xmlFree(c);
          }
        break;
      default: break;
    }
    return 0;
  }
  """

  # Eigen — header-only C++ linear algebra. No sources to compile (the lane grabs the extensionless umbrella
  # headers as companions + -I/work); the smoke main does a 2x2 matrix multiply.
  @eigen_main ~S"""
  #include <cstdio>
  #include <Eigen/Dense>
  int main() {
    Eigen::Matrix2d a; a << 1, 2, 3, 4;
    Eigen::Matrix2d b = a * a;
    printf("%g %g\n", b(0, 0), b(1, 1));
    return 0;
  }
  """

  # libpng — built WITH zlib via the :deps multi-tarball lane (zlib's sources compiled alongside, minus its
  # gzFile API which needs lseek). pnglibconf.h is configure-generated → vendored from scripts/*.prebuilt.
  @libpng_config File.read!(Path.join(__DIR__, "../priv/libpng/pnglibconf.h"))
  @png_main ~S"""
  #include <stdio.h>
  #include "png.h"
  #include "zlib.h"
  int main(void) { printf("libpng %s zlib %s\n", PNG_LIBPNG_VER_STRING, zlibVersion()); return 0; }
  """

  @csource [
    %{
      name: "xml2",
      url: "https://download.gnome.org/sources/libxml2/2.13/libxml2-2.13.5.tar.xz",
      sha: "74fc163217a3964257d3be39af943e08861263c4231f9ef5b496b6f6d4c7b2b6",
      build_opts: [
        src_globs: ["*.{c,h}", "include/**/*.h"],
        exclude: ~w(nanoftp.c nanohttp.c xmlcatalog.c xmllint.c testModule.c testapi.c testchar.c testdict.c testlimits.c testparser.c testrecurse.c testThreads.c runtest.c runsuite.c runxmlconf.c),
        cflags: ["-DHAVE_CONFIG_H", "-Wno-implicit-function-declaration", "-I/work", "-I/work/include"],
        extra_sources: [{"config.h", @libxml2_config}, {"include/libxml/xmlversion.h", @libxml2_xmlversion}, {"xmlmain.c", @libxml2_main}]
      ]
    },
    %{
      name: "eigen",
      url: "https://gitlab.com/libeigen/eigen/-/archive/3.4.0/eigen-3.4.0.tar.gz",
      sha: "8586084f71f9bde545ee7fa6d00288b264a2b7ac3607b974e54d13e7162c1c72",
      build_opts: [
        src_globs: ["Eigen/**/*"],
        cflags: ["-I/work", "-fno-exceptions"],
        extra_sources: [{"eigmain.cpp", @eigen_main}]
      ]
    },
    %{
      name: "png",
      url: "https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.43.tar.gz",
      sha: "fecc95b46cf05e8e3fc8a414750e0ba5aad00d89e9fdf175e94ff041caf1a03a",
      build_opts: [
        src_globs: ["*.{c,h}"],
        exclude: ~w(pngtest.c example.c gzlib.c gzread.c gzwrite.c gzclose.c),
        deps: [
          %{
            url: "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz",
            sha: "9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23",
            subdir: "zlib",
            globs: ["*.{c,h}"]
          }
        ],
        cflags: ["-I/work/zlib", "-I/work"],
        extra_sources: [{"pnglibconf.h", @libpng_config}, {"pngmain.c", @png_main}]
      ]
    },
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
    },
    %{
      name: "b3",
      url: "https://codeload.github.com/BLAKE3-team/BLAKE3/tar.gz/refs/tags/1.5.4",
      sha: "ddd24f26a31d23373e63d9be2e723263ac46c8b6d49902ab08024b573fd2a416",
      build_opts: [
        src_globs: ["c/*.{c,h}"],
        exclude: ~w(blake3_avx2.c blake3_avx512.c blake3_neon.c blake3_sse2.c blake3_sse41.c example.c main.c),
        cflags: ~w(-DBLAKE3_NO_SSE2 -DBLAKE3_NO_SSE41 -DBLAKE3_NO_AVX2 -DBLAKE3_NO_AVX512 -DBLAKE3_USE_NEON=0),
        extra_sources: [{"b3main.c", @b3_main}]
      ]
    },
    %{
      name: "br",
      url: "https://codeload.github.com/google/brotli/tar.gz/refs/tags/v1.1.0",
      sha: "e720a6ca29428b803f4ad165371771f5398faba397edf6778837a18599ea13ff",
      build_opts: [
        src_globs: ["c/include/brotli/*.h", "c/common/*.{c,h}", "c/enc/*.{c,h}", "c/dec/*.{c,h}"],
        cflags: ["-I/work/c/include"],
        extra_sources: [{"brmain.c", @br_main}]
      ]
    },
    %{
      name: "argon2",
      url: "https://monocypher.org/download/monocypher-4.0.2.tar.gz",
      sha: "38d07179738c0c90677dba3ceb7a7b8496bcfea758ba1a53e803fed30ae0879c",
      build_opts: [src_globs: ["src/monocypher.{c,h}"], extra_sources: [{"a2main.c", @argon2_main}]]
    },
    %{
      name: "mujs",
      url: "https://codeload.github.com/ccxvii/mujs/tar.gz/refs/tags/1.3.5",
      sha: "78a311ae4224400774cb09ef5baa2633c26971513f8b931d3224a0eb85b13e0b",
      build_opts: [src_globs: ["*.{c,h}"], exclude: ~w(main.c one.c), extra_sources: [{"mujs_main.c", @mujs_main}]]
    },
    %{
      name: "zforth",
      url: "https://codeload.github.com/zevv/zForth/tar.gz/41db72d165c1539d57f3f79970fc57ea881a79dc",
      sha: "34c578ec2aa979786387e5f244fa933b6b040f9a6f18888ed2cc4273ef06df8d",
      build_opts: [
        src_globs: ["src/zforth/zforth.{c,h}", "src/linux/zfconf.h"],
        extra_sources: [{"zfmain.c", @zforth_main}, {"core_zf.h", @zforth_core}]
      ]
    },
    %{
      name: "tar",
      url: "https://codeload.github.com/rxi/microtar/tar.gz/27076e1b9290e9c7842bb7890a54fcf172406c84",
      sha: "08d28c3f3b3a3776123f7a375b47dbd7059c9e883977b1a99a518499c756e872",
      build_opts: [src_globs: ["src/microtar.{c,h}"], extra_sources: [{"tar_main.c", @tar_main}]]
    },
    %{
      name: "onig",
      url: "https://github.com/kkos/oniguruma/releases/download/v6.9.10/onig-6.9.10.tar.gz",
      sha: "2a5cfc5ae259e4e97f86b68dfffc152cdaffe94e2060b770cb827238d769fc05",
      build_opts: [
        src_globs: ["src/*.{c,h}"],
        exclude: ~w(mktable.c),
        include_only: ~w(unicode_egcb_data.c unicode_fold_data.c unicode_property_data_posix.c unicode_property_data.c unicode_wb_data.c),
        cflags: ["-I/work/src"],
        extra_sources: [{"src/config.h", @onig_config}, {"onigmain.c", @onig_main}]
      ]
    },
    %{
      name: "expat",
      url: "https://github.com/libexpat/libexpat/releases/download/R_2_8_1/expat-2.8.1.tar.gz",
      sha: "a52eb72108be160e190b5cafa5bba8663f1313f2013e26060d1c18e26e31067b",
      build_opts: [
        src_globs: ["lib/*.{c,h}"],
        include_only: ["xmltok_impl.c", "xmltok_ns.c"],
        exclude: ~w(random_arc4random_buf.c random_arc4random.c random_dev_urandom.c random_getrandom.c random_rand_s.c),
        cflags: ["-DHAVE_EXPAT_CONFIG_H", "-I/work", "-I/work/lib"],
        extra_sources: [{"expat_config.h", @expat_config}, {"xpmain.c", @expat_main}]
      ]
    },
    %{
      name: "mbedtls",
      url: "https://codeload.github.com/Mbed-TLS/mbedtls/tar.gz/refs/tags/mbedtls-3.6.6",
      sha: "de654c64688d0f6c71caf7336010e1fb54070e6e3d1df3999ee432ab59d0dbde",
      build_opts: [
        src_globs: ["library/*.{c,h}", "include/**/*.h"],
        cflags: ["-I/work/include", "-I/work/library", "-DMBEDTLS_CONFIG_FILE=\"mbedtls_min.h\""],
        extra_sources: [{"mbedtls_min.h", @mbedtls_config}, {"sha_main.c", @mbedtls_main}]
      ]
    },
    %{
      name: "harfbuzz",
      url: "https://codeload.github.com/harfbuzz/harfbuzz/tar.gz/refs/tags/14.2.1",
      sha: "3c2a9006a7e1bf58737e557014d7882c554c628fb379a9f00008f5ea53dbbdfb",
      build_opts: [
        src_globs: ["src/**/*.{cc,hh,h}"],
        compile_only: ["harfbuzz.cc", "hbmain.c"],
        cflags: ["-DHB_NO_MT", "-fno-exceptions", "-I/work/src"],
        extra_sources: [{"hbmain.c", @harfbuzz_main}]
      ]
    },
    %{
      name: "freetype",
      url: "https://gitlab.freedesktop.org/freetype/freetype/-/archive/VER-2-13-3/freetype-VER-2-13-3.tar.gz",
      sha: "bc5c898e4756d373e0d991bab053036c5eb2aa7c0d5c67e8662ddc6da40c4103",
      build_opts: [
        src_globs: ["src/**/*.{c,h}", "include/**/*.h"],
        compile_only: @freetype_umbrellas,
        cflags: ["-DFT2_BUILD_LIBRARY", "-I/work/include"],
        extra_sources: [{"include/freetype/config/ftmodule.h", @freetype_ftmodule}, {"ftmain.c", @freetype_main}]
      ]
    },
    %{
      name: "wuffs",
      url: "https://codeload.github.com/google/wuffs/tar.gz/refs/tags/v0.4.0-alpha.9",
      sha: "9e4cd20abe96e6c4c6ede9c3057108860126e7be2e2c3e35515476c250be1c13",
      build_opts: [
        src_globs: ["release/c/wuffs-v0.3.c"],
        include_only: ["wuffs-v0.3.c"],
        cflags: ["-I/work/release/c"],
        extra_sources: [{"wmain.c", @wuffs_driver}]
      ]
    },
    %{
      name: "sodium",
      url: "https://download.libsodium.org/libsodium/releases/libsodium-1.0.20-stable.tar.gz",
      sha: "b6b1d2a8802cd8bfa611638c0e9ce31d14ef324e16062c39a76854091cba6d7f",
      build_opts: [
        src_globs: ["src/libsodium/**/*.{c,h}"],
        cflags: ["-I/work/src/libsodium/include", "-I/work/src/libsodium/include/sodium"],
        extra_sources: [{"src/libsodium/include/sodium/version.h", @sodium_version}, {"sodium_main.c", @sodium_main}]
      ]
    },
    %{
      name: "pcre2",
      url: "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.gz",
      sha: "c08ae2388ef333e8403e670ad70c0a11f1eed021fd88308d7e02f596fcd9dc16",
      build_opts: [
        src_globs: ["src/pcre2_*.c", "src/*.h"],
        exclude: ~w(pcre2_dftables.c pcre2_jit_test.c pcre2_fuzzsupport.c),
        cflags: ["-DPCRE2_CODE_UNIT_WIDTH=8", "-DHAVE_CONFIG_H", "-I/work"],
        extra_sources: [{"config.h", @pcre2_config}, {"pcre2.h", @pcre2_h}, {"pcre2_chartables.c", @pcre2_tables}, {"pmain.c", @pcre2_main}]
      ]
    }
  ]

  # Lane C — inline Rust recipes (built via mrustc.wasm → clang.wasm → wasm, full std, zero native exec).
  # Each tool is just data: a name + std-only source. Proves/extends the Rust lane in the catalog.
  @wfreq_src ~S"""
  use std::io::Read;
  use std::collections::HashMap;
  fn main() {
      let mut s = String::new();
      std::io::stdin().read_to_string(&mut s).unwrap();
      let mut counts: HashMap<String, u32> = HashMap::new();
      for w in s.split_whitespace() {
          *counts.entry(w.to_string()).or_insert(0) += 1;
      }
      let mut v: Vec<(String, u32)> = counts.into_iter().collect();
      v.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
      for (w, c) in v {
          println!("{}\t{}", c, w);
      }
  }
  """

  # `rgx`: line grep via the `regex` crate (+ transitive deps regex-syntax/aho-corasick/memchr) —
  # proves Lane C resolves a crates.io DEPENDENCY graph, not just std (parallel to tmpl on Lane D).
  @rgx_src ~S"""
  use std::io::Read;
  use regex::Regex;
  fn main() {
      let args: Vec<String> = std::env::args().collect();
      let pat = args.get(1).map(|s| s.as_str()).unwrap_or(".");
      let re = Regex::new(pat).unwrap();
      let mut s = String::new();
      std::io::stdin().read_to_string(&mut s).unwrap();
      for line in s.lines() {
          if re.is_match(line) { println!("{}", line); }
      }
  }
  """

  @rust [
    %{name: "wfreq", source: @wfreq_src, deps: [], mode: :argv},
    %{name: "rgx", source: @rgx_src, deps: ["regex"], mode: :argv}
  ]

  # Lane D — pure-Python tools riding the CPython.wasm interpreter (Lane A) with a FROZEN site-packages
  # dir (vendored under priv/pytools, mounted at /pkgs) + a frozen `-c` script. Zero native exec; just
  # the interpreter + .py files. Each tool = data (name + script); the package universe is shared.
  @yaml_script "import sys; sys.path.insert(0, '/pkgs'); import yaml, json; print(json.dumps(yaml.safe_load(sys.stdin.read()), sort_keys=True))"

  # `tmpl`: Jinja2 templating (Jinja2 + its dep MarkupSafe, both vendored — proves Lane D handles
  # MULTI-package deps). stdin = JSON {"template": "...", "data": {...}} → the rendered text.
  @tmpl_script "import sys, json; sys.path.insert(0, '/pkgs'); from jinja2 import Template; req = json.loads(sys.stdin.read()); sys.stdout.write(Template(req['template']).render(**req.get('data', {})))"

  @python_tools [
    %{name: "yaml", script: @yaml_script},
    %{name: "tmpl", script: @tmpl_script}
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

  @doc "The Rust inline-source catalog (Lane C — name + std-only source + argv mode)."
  def rust_catalog, do: @rust

  @doc """
  Build + register every :rust tool in-sandbox (mrustc.wasm → clang.wasm, full std; one-time, then
  persisted + reloaded at boot). Returns `%{name => :ok | {:error, reason}}`.
  """
  def seed_rust, do: Map.new(@rust, fn r -> {r.name, seed_rust_one(r)} end)

  @doc "Build + register one :rust entry by name (or the entry map)."
  def seed_rust_one(name) when is_binary(name) do
    case Enum.find(@rust, &(&1.name == name)) do
      nil -> {:error, :unknown_rust_entry}
      r -> seed_rust_one(r)
    end
  end

  def seed_rust_one(%{name: n, source: src, mode: mode} = entry) do
    # idempotent: skip if already reloaded from the persisted cache (same as seed_csource_one)
    if n in CommandRegistry.list() do
      :ok
    else
      deps = Map.get(entry, :deps, [])

      case CommandRegistry.build_and_register_inline(n, "rust", src, deps, mode) do
        {:ok, _} -> :ok
        other -> other
      end
    end
  end

  @doc "The pure-Python tools catalog (Lane D — name + frozen `-c` script; ride CPython + priv/pytools)."
  def python_tools_catalog, do: @python_tools

  @doc """
  Register every :python tool as a first-class command (CPython.wasm + frozen script + the vendored
  priv/pytools site-packages mounted at /pkgs). No build/fetch beyond CPython itself — fast.
  """
  def seed_python_tools, do: Map.new(@python_tools, fn t -> {t.name, seed_python_tool_one(t)} end)

  @doc "Register one :python tool by name (or the entry map)."
  def seed_python_tool_one(name) when is_binary(name) do
    case Enum.find(@python_tools, &(&1.name == name)) do
      nil -> {:error, :unknown_python_tool}
      t -> seed_python_tool_one(t)
    end
  end

  def seed_python_tool_one(%{name: n, script: script}) do
    # ensure the CPython interpreter (Lane A) is registered, then wrap it: frozen ["-c", script] +
    # the vendored pure-Python packages mounted read-only at /pkgs.
    if "python" not in CommandRegistry.list(), do: seed_one("python")

    case CommandRegistry.current("python") do
      {:wasm, py_path, _mode} ->
        pkgs = Application.app_dir(:workbooks, "priv/pytools")
        CommandRegistry.register(n, py_path, :argv, %{dirs: ["#{pkgs}::/pkgs"], argv: ["-c", script]})

      _ ->
        {:error, :python_not_registered}
    end
  end
end
