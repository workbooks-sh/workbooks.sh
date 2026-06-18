/* work in-sandbox Svelte lane (wb-2ku.5). Runs inside qjs-run.wasm — same Javy.IO stdin→stdout
 * contract as bundle/bundlejob.js and ts/tsjob.js. ZERO native execution: no node/bun/vite/rollup.
 *
 * This file is CONCATENATED BEFORE bundlejob.js by Workbooks.Compilers.svelte_bundle_dir. It does
 * NOT re-implement resolution or bundling — it registers a PRE-BUNDLE HOOK (globalThis.__wbPreBundle)
 * that transforms the file-map (every `.svelte` source → the JS module svelte.compile() emits) and
 * then hands the SAME map to bundlejob's unchanged bundle(). DRY: one bundler, one resolver; Svelte
 * is "a transform over the file-map" (the lane model documented in bundlejob.js). bundlejob's driver
 * — always at the BOTTOM of the concatenated source — reads stdin and invokes the hook; this file
 * only registers it (and reuses bundlejob's helpers via globalThis.__wbBundle, published before the
 * driver runs).
 *
 * stdin  : JSON {"entry": "<relpath>", "files": {... project files incl. .svelte sources AND the
 *          hoisted node_modules/ tree containing the `svelte` package ...}, "svelteOptions": {...}}
 *          The hook compiles .svelte BEFORE bundling, so the entry may be a .js that imports a
 *          .svelte component, or a .svelte file itself.
 * stdout : a single self-contained CommonJS bundle (bundlejob's output), CSS injected at runtime
 *          (compilerOptions.css = "injected") so there is exactly ONE output artifact.
 *
 * Svelte version: we require `svelte/compiler` from the supplied node_modules through bundlejob's
 * own resolver, so whatever version was hoisted is what runs. svelte.compile is a PURE function of
 * (source, options) with no node API surface beyond what the QuickJS harness already provides
 * (TextEncoder/Decoder, console), which is exactly why the compiler — unlike the dev server — runs
 * in-sandbox. The Elixir side pins the version it fetches; see svelte_lane_test.exs for the version
 * actually verified.
 */

(function () {
  "use strict";

  function isSvelte(p) { return /\.svelte$/.test(p); }

  // Load svelte/compiler from the hoisted node_modules. The compiler IS a prebuilt single-file UMD
  // bundle (svelte/compiler.cjs in v4, compiler.js in v5) with NO require()s of its own — so we eval
  // its source DIRECTLY in a synthetic CJS scope and capture module.exports. We deliberately do NOT
  // route it through bundlejob.bundle(): bundling a 1.5 MB prebuilt bundle is both pointless and
  // ruinously slow under QuickJS, and the bundler's ESM→CJS regex pass corrupts a file this size
  // (matches `export`/`import` substrings inside string literals). Resolution reuses bundlejob's
  // resolveFile so the package.json "main"/extension probing stays in one place (DRY).
  function loadSvelteCompiler(files) {
    var B = globalThis.__wbBundle;
    // svelte/compiler → node_modules/svelte/compiler{,.js,.cjs} etc., plus explicit fallbacks for
    // packages that only expose the compiler via the "exports" map (which our resolver doesn't read).
    var target = B.resolveFile(files, "node_modules/svelte/compiler");
    if (!target) {
      var guesses = [
        "node_modules/svelte/compiler.cjs",        // svelte 4
        "node_modules/svelte/compiler.js",         // svelte 5
        "node_modules/svelte/compiler/index.js",
        "node_modules/svelte/src/compiler/index.js"
      ];
      for (var i = 0; i < guesses.length; i++) if (files[guesses[i]] != null) { target = guesses[i]; break; }
    }
    if (!target) throw "cannot resolve 'svelte/compiler' from node_modules — is the svelte package hoisted?";

    var src = files[target];
    // Synthetic CJS scope via new Function (NOT eval — eval would run the UMD wrapper in global
    // scope where `module`/`exports` are undefined, sending it down the `global.svelte=` branch).
    // new Function injects module/exports/require as locals so the UMD `typeof module !== undefined`
    // branch runs `factory(exports)` and the compiler lands on module.exports. The compiler has no
    // deps so require throws if ever hit. The package is what the caller installed — no extra privilege.
    var module = { exports: {} };
    var require = function (n) { throw "svelte/compiler unexpectedly require()d '" + n + "'"; };
    var fn = new Function("module", "exports", "require", "global", "globalThis", src);
    fn(module, module.exports, require, globalThis, globalThis);

    var svelte = (module.exports && typeof module.exports.compile === "function") ? module.exports
               : (globalThis.svelte && typeof globalThis.svelte.compile === "function" ? globalThis.svelte : null);
    if (!svelte || typeof svelte.compile !== "function")
      throw "loaded 'svelte/compiler' (" + target + ") but it has no .compile() — unexpected package shape";
    return svelte;
  }

  // Pick the generate mode that THIS compiler understands. Svelte 5 uses generate:'client'|'server';
  // Svelte 3/4 use generate:'dom'|'ssr'. We can't import the version statically, so we try the
  // svelte-5 option set first and fall back to the svelte-4 set if compile rejects it.
  function compileOne(svelte, source, filename, userOpts) {
    var base = { filename: filename, css: "injected" };
    for (var k in (userOpts || {})) base[k] = userOpts[k];

    var attempts = [
      mergeGen(base, "client"), // svelte 5
      mergeGen(base, "dom")     // svelte 3/4
    ];
    var lastErr;
    for (var i = 0; i < attempts.length; i++) {
      try {
        var res = svelte.compile(source, attempts[i]);
        if (res && res.js && typeof res.js.code === "string") return res.js.code;
        // very old svelte returned {code} at the top level
        if (res && typeof res.code === "string") return res.code;
      } catch (e) { lastErr = e; }
    }
    throw "svelte.compile failed for " + filename + ": " + (lastErr || "unknown — no js output");
  }

  function mergeGen(base, gen) {
    var o = {}; for (var k in base) o[k] = base[k]; o.generate = gen; return o;
  }

  // The hook: compile every .svelte file in place, then return the rewritten input for bundle().
  // Compiled output is ESM (import/export); bundlejob's esmToCjs handles that downstream, so a
  // .svelte file becomes an ordinary JS module in the map under its OWN path — require("./Foo.svelte")
  // already points at it (relative resolution is extension-exact, and .svelte stays the key).
  globalThis.__wbPreBundle = function (input) {
    var files = input.files;
    var svelteFiles = [];
    for (var p in files) if (isSvelte(p)) svelteFiles.push(p);
    if (svelteFiles.length === 0) return input; // nothing to do — behaves like a plain bundle

    var svelte = loadSvelteCompiler(files);
    for (var i = 0; i < svelteFiles.length; i++) {
      var p2 = svelteFiles[i];
      files[p2] = compileOne(svelte, files[p2], p2, input.svelteOptions);
    }
    return input;
  };
})();
// bundlejob.js (concatenated after this) reads stdin and invokes the hook above.
