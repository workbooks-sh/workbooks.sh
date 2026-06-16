# sandbox — command reference

# How to read this

  Each entry is `command` — what it does — how to call it (stdin / argv). All run
  under wasmtime (WASI), stdin → stdout. File-mode commands need a `--dir` preopen.

# Languages

  - `python` — CPython 3.12, full stdlib. `run("python", "", ["-c", "print(2**10)"])` →
    `1024`. Scripts: mount a dir (`--dir`) and pass the path. C-extensions don't load
    (pure-Python only); net/subprocess are sandbox-stubbed.
  - `ruby` — Ruby 3.2. `run("ruby", "", ["-e", "puts 2**10"])`.
  - `php` — PHP (php-cgi). `run("php", "", ["-r", "echo 6*7;"])`.
  - `lua` — Lua 5.4. `run("lua", "", ["-e", "print(6*7)"])`.
  - `wren` — Wren (class-based). `run("wren", "", ["-e", "System.print(6*7)"])`.
  - `mujs` — MuJS (tiny ES5). `zforth` — a Forth interpreter.
  - `agda` — Agda 2.8 (dependently-typed language / proof assistant; GHC-wasm build).
    `run("agda", "", ["--version"])`. Batch typecheck needs the prim datadir mounted (`--dir`).

# JavaScript engines

  - `qjs` — QuickJS-ng, full ES2023. `run("qjs", "", ["-e", "6*7"])` → `42` (prints the
    expression's value).
  - `duk` — Duktape, ES5/ES2015. Same `-e` shape. Lighter, older language level.

# Compression (each: stdin → compressed stdout; `-d` decompresses)

  - `gz`  — gzip (interops with gzip/gunzip). `run("gz", data, [])` / `run("gz", c, ["-d"])`.
  - `lz4` — LZ4 frame (interops with the lz4 tool).
  - `zstd` — Zstandard (`.zst`). Best general ratio/speed.
  - `br`  — brotli. Best for text/web payloads.

# Hashing (stdin → hex digest)

  - `b2` — BLAKE2b-512. `run("b2", data, [])`.
  - `b3` — BLAKE3-256 (fastest modern hash). `run("b3", data, [])`.
  - `argon2` — Argon2 password hash. `run("argon2", "password", [])`.
  (For SHA-256/MD5/etc. use `coreutils sha256sum` / `md5sum`, or python's `hashlib`.)

# Crypto

  - `sodium` — libsodium (NaCl): BLAKE2b of stdin → hex. The full NaCl suite (box/secretbox/
    sign/pwhash) is linked in. `run("sodium", data, [])`.
  - `mbedtls` — mbedTLS SHA-256 of stdin → hex. `run("mbedtls", data, [])`.
  - `openssl` — the full OpenSSL 1.1.1 CLI: `run("openssl", "", ["version"])`,
    `run("openssl", data, ["dgst", "-sha256"])`, `enc` / `genrsa` / `x509` / `rand` / `base64`.

# Fonts & text shaping

  - `freetype` — FreeType font engine. `run("freetype", "", [])` prints the version; the lib
    (TrueType/CFF/Type1/autofit/SDF) is linked for `FT_New_Face` glyph rendering (mount a font `--dir`).
  - `harfbuzz` — HarfBuzz text shaping. `run("harfbuzz", "", [])` → version; `hb_shape` ready.

# Image

  - `jpeg` — libjpeg-turbo: `cjpeg` / `djpeg` / `jpegtran` (PPM↔JPEG). `run("jpeg", ppm, ["cjpeg"])`.
  - `png` — libpng (+zlib, via the multi-tarball lane). `run("png", "", [])` prints versions; the
    lib is linked for PNG decode/encode.

# XML

  - `expat` — Expat SAX parser. `run("expat", "<a><b/><c/></a>", [])` → element count `3`.
  - `xml2` — libxml2 (XPath/DOM, richer than expat). Evaluate an XPath over stdin XML:
    `run("xml2", "<root><item>a</item><item>b</item></root>", ["count(//item)"])` → `2`.

# Regex

  - `onig` — Oniguruma (Ruby/PHP's engine), grep. pattern in argv:
    `run("onig", "apple\nbanana", ["^b"])` → `banana`.
  - `rgx` — Rust `regex` crate grep. `wfreq` — word frequency.

# Math

  - `eigen` — Eigen linear algebra. `run("eigen", "", [])` runs a 2×2 matrix-multiply demo (`7 22`);
    the dense/sparse/decomposition library is linked.

# Document conversion

  - `md` — CommonMark markdown → HTML. `run("md", "# Hi", [])` → `<h1>Hi</h1>`.
  - `pandoc` — the universal document converter (markdown/HTML/LaTeX/RST/docx/EPUB/…). stdin → stdout:
    `run("pandoc", "# Hello", ["-f", "markdown", "-t", "html"])` → `<h1 ...>Hello</h1>`.

# Data formats (Lane D, JS on Javy/QuickJS)

  - `arrow` — Apache Arrow: JSON `{col:[…]}` → an Arrow table (prints rows + IPC byte length).
    `run("arrow", "{\"a\":[1,2,3]}", [])`.
  - `protobuf` — parse a .proto schema → message type names. `run("protobuf", proto_text, [])`.

# Web / render (Lane D, JS on Javy/QuickJS)

  - `glimmer` — Glimmer/Ember template → wire-format JSON. `run("glimmer", "<div>{{name}}</div>", [])`.
  - `enhance` — server-side render (@enhance/ssr). `run("enhance", "hello", [])` → rendered HTML.
  - `pdf` — stdin text → a one-page PDF (pdf-lib; binary out). `run("pdf", "hello world", [])`.

# Archive

  - `tar` — tar create / extract (microtar). File I/O via `--dir`.

# Data / docs / encoding

  - `sqlite3` — SQL on stdin. `run("sqlite3", "SELECT 6*7;", [])`. Persistent DB needs `--dir`.
  - `jq` — JSON. Built-in: filter on stdin's first line, JSON after (legacy `:stdin1` mode).
  - `md` — CommonMark markdown → HTML. `run("md", "# Hi", [])` → `<h1>Hi</h1>`.
  - `qr` — text → ASCII QR. `run("qr", "https://…", [])` (`##` = dark module).

# Unix utilities

  - `coreutils` — uutils multicall, ~100 applets. Prepend the applet to argv:
    `run("coreutils", stdin, ["wc", "-l"])`, `run("coreutils", "", ["seq", "5"])`,
    `["sha256sum"]`, `["sort"]`, `["base64"]`, `["cut", "-f1"]`, … FS applets need `--dir`.

# WebAssembly tooling (WABT)

  - `wat2wasm` `wasm2wat` `wasm-validate` `wasm-objdump` `wasm-strip` `wasm-decompile`
    `wasm-interp` `wasm-stats` `wasm2c` `wast2json` `wat-desugar` `spectest-interp`.
    File I/O via `--dir`. `run("wat2wasm", "", ["--version"])`.

# Config / built-in-sandbox language tools

  - `yaml` — YAML → JSON (PyYAML on CPython, Lane D). `run("yaml", "a: 1\nb: [x, y]", [])` →
    `{"a": 1, "b": ["x", "y"]}`. Distinct: YAML is in no stdlib we have.
  - `tmpl` — Jinja2 templating (Jinja2 + MarkupSafe on CPython, Lane D multi-package). stdin =
    JSON `{"template","data"}` → rendered text. `run("tmpl", json, [])`.
  - `wfreq` — word frequency, desc by count (a Rust tool built via mrustc→clang, Lane C).
    `run("wfreq", "the cat the dog the", [])` → `3⇥the / 1⇥cat / 1⇥dog`.
  - `rgx` — regex line grep via the Rust `regex` crate (Lane C with a crates.io dep). pattern in argv:
    `run("rgx", "apple\nbanana", ["^b"])` → `banana`.

# Misc

  - `prolog` — Trealla. One-shot goal: `run("prolog", "", ["-g", "X is 6*7, write(X), nl, halt"])`.
  - `wasm3` — a wasm interpreter (run a nested guest module).

# Adding a tool (for the maintainer)

  Edit `Workbooks.Pallet`. A prebuilt WASI `.wasm` → append to `@catalog` (`:wasm` /
  `:archive` / `:archive_many` / `:zip`). A buildable C source → append to `@csource`
  with `build_opts` (`:src_subdir` | `:src_globs` | `:exclude` | `:extra_sources` [inject a
  minimal main] | `:cflags`). The in-sandbox C lane handles multi-file, headers, generated
  `.inc`, setjmp/longjmp, wasi-libc emulated features, host-escape stubs, unity builds, AND
  structured multi-dir trees — so most real C libraries build with a few lines of data.
