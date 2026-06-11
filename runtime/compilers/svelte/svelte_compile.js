/* wb svelte COMPILE-ONLY lane (wb-feto) — runs in qjs-run.wasm. Loads svelte/compiler from the
 * supplied node_modules and compiles every .svelte source in the file-map to JS (in place), then
 * writes the transformed file-map back as JSON. The HOST then bundles that map with esbuild
 * (native-fast) — splitting the irreducible QuickJS COMPILE from the now-fast BUNDLE. This replaces
 * the old sveltejob+bundlejob (compile AND bundle in QuickJS) for the bundle half.
 *
 * stdin : {"files": {<path>: <source>, ... incl. the hoisted node_modules/svelte}, "svelteOptions": {}}
 * stdout: {"files": {... same map with every .svelte entry replaced by its compiled JS (css injected)}}
 * The compiler-load + compileOne logic mirrors sveltejob.js exactly (same version probing, same
 * generate:'client'|'dom' fallback) — only the bundling is removed.
 */
(function () {
  "use strict";

  function readStdin() {
    var chunks = [], total = 0, CH = 1 << 20, b = new Uint8Array(CH);
    for (;;) { var n = Javy.IO.readSync(0, b); if (n <= 0) break; chunks.push(b.slice(0, n)); total += n; }
    var out = new Uint8Array(total), o = 0;
    for (var i = 0; i < chunks.length; i++) { out.set(chunks[i], o); o += chunks[i].length; }
    return new TextDecoder().decode(out);
  }
  function write(s) { Javy.IO.writeSync(1, new TextEncoder().encode(s)); }
  function err(s) { Javy.IO.writeSync(2, new TextEncoder().encode(s + "\n")); }
  function isSvelte(p) { return /\.svelte$/.test(p); }

  function resolveCompiler(files) {
    var guesses = [
      "node_modules/svelte/compiler.cjs",        // svelte 4
      "node_modules/svelte/compiler.js",         // svelte 5
      "node_modules/svelte/compiler/index.js",
      "node_modules/svelte/src/compiler/index.js"
    ];
    for (var i = 0; i < guesses.length; i++) if (files[guesses[i]] != null) return guesses[i];
    return null;
  }

  function loadSvelteCompiler(files) {
    var target = resolveCompiler(files);
    if (!target) throw "cannot resolve 'svelte/compiler' from node_modules — is the svelte package hoisted?";
    var src = files[target];
    // Synthetic CJS scope via new Function (see sveltejob.js for why not eval): module/exports/require
    // are locals so the UMD `typeof module !== undefined` branch lands the compiler on module.exports.
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

  function mergeGen(base, gen) { var o = {}; for (var k in base) o[k] = base[k]; o.generate = gen; return o; }

  function compileOne(svelte, source, filename, userOpts) {
    var base = { filename: filename, css: "injected" };
    for (var k in (userOpts || {})) base[k] = userOpts[k];
    var attempts = [mergeGen(base, "client") /* svelte 5 */, mergeGen(base, "dom") /* svelte 3/4 */];
    var lastErr;
    for (var i = 0; i < attempts.length; i++) {
      try {
        var res = svelte.compile(source, attempts[i]);
        if (res && res.js && typeof res.js.code === "string") return res.js.code;
        if (res && typeof res.code === "string") return res.code;
      } catch (e) { lastErr = e; }
    }
    throw "svelte.compile failed for " + filename + ": " + (lastErr || "unknown — no js output");
  }

  try {
    var input = JSON.parse(readStdin());
    var files = input.files;
    var svelteFiles = [];
    for (var p in files) if (isSvelte(p)) svelteFiles.push(p);
    if (svelteFiles.length) {
      var svelte = loadSvelteCompiler(files);
      for (var i = 0; i < svelteFiles.length; i++) {
        files[svelteFiles[i]] = compileOne(svelte, files[svelteFiles[i]], svelteFiles[i], input.svelteOptions);
      }
    }
    write(JSON.stringify({ files: files }));
  } catch (e) {
    err("svelte-compile error: " + e + (e && e.stack ? "\n" + e.stack : ""));
  }
})();
