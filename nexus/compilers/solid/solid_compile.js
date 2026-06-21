/* work solid COMPILE-ONLY lane — runs in qjs-run.wasm. Loads the vendored @babel/standalone bundle
 * (with babel-preset-solid registered as "solid") from the supplied node_modules and transforms every
 * .jsx/.tsx source in the file-map to JS (in place), then writes the file-map back as JSON. Mirrors
 * svelte/svelte_compile.js exactly (same files-map stdin/stdout contract), differing only in the
 * compiler loaded + the transform call. Zero native execution.
 *
 * stdin : {"files": {<path>: <source>, ..., "node_modules/@babel/standalone/babel.js": <bundle>}}
 * stdout: {"files": {... same map with every .jsx/.tsx entry replaced by its compiled JS}}
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
  function isJsx(p) { return /\.(jsx|tsx)$/.test(p); }

  function loadBabel(files) {
    var path = "node_modules/@babel/standalone/babel.js";
    var src = files[path];
    if (src == null) throw "cannot resolve '@babel/standalone' from node_modules — is the bundle hoisted?";
    // The vendored bundle is an IIFE that sets globalThis.Babel (with preset 'solid' registered).
    var fn = new Function("globalThis", "self", "window", src);
    fn(globalThis, globalThis, globalThis);
    var Babel = globalThis.Babel;
    if (!Babel || typeof Babel.transform !== "function")
      throw "loaded babel bundle but it has no Babel.transform — unexpected bundle shape";
    return Babel;
  }

  function compileOne(Babel, source, filename) {
    var res = Babel.transform(source, {
      presets: ["solid"],
      filename: filename,
      // tsx support comes from the typescript preset; keep it minimal + JSX via solid.
      sourceMaps: false
    });
    if (res && typeof res.code === "string") return res.code;
    throw "babel.transform produced no code for " + filename;
  }

  try {
    var input = JSON.parse(readStdin());
    var files = input.files;
    var jsxFiles = [];
    for (var p in files) if (isJsx(p)) jsxFiles.push(p);
    if (jsxFiles.length) {
      var Babel = loadBabel(files);
      for (var i = 0; i < jsxFiles.length; i++) {
        files[jsxFiles[i]] = compileOne(Babel, files[jsxFiles[i]], jsxFiles[i]);
      }
    }
    write(JSON.stringify({ files: files }));
  } catch (e) {
    err("solid-compile error: " + e + (e && e.stack ? "\n" + e.stack : ""));
  }
})();
