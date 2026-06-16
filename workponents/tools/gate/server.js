// gate · static server — serves the workponents tree to the headless harness.
//
// The demos resolve `lit` from a CDN import map (esm.sh); the gate must run
// OFFLINE (gate-c network-blocks engine chunks, and we never want a flaky CDN in
// CI). So this server serves the repo AND a synthetic `/__lit/all.js` mount —
// a single, self-contained lit bundle (tools/gate/vendor/lit-all.js, one shared
// lit-html instance so the directives interoperate). The harness page injects an
// import map mapping `lit` AND every `lit/directives/*.js` specifier the elements
// use onto that one file. Zero CDN, deterministic, no per-run bundling.
//
// It also exposes `/__gate/page.html` (the mount harness) and resolves any path
// under the workponents root, so element source + theme tokens load by their
// real relative paths exactly as the demos do.

import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join, normalize, extname } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
export const ROOT = normalize(join(__dirname, "..", ".."));      // workponents/
export const NODE_MODULES = join(ROOT, "node_modules");

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".map": "application/json; charset=utf-8",
};

async function tryRead(path) {
  try {
    const s = await stat(path);
    if (s.isDirectory()) return await tryRead(join(path, "index.js"));
    return await readFile(path);
  } catch {
    return null;
  }
}

/**
 * Start the gate server. Returns { url, close }.
 * `/__lit/<x>` → node_modules/lit/<x>  ·  everything else → workponents root.
 */
export function startServer(port = 0) {
  return new Promise((resolve) => {
    const server = createServer(async (req, res) => {
      try {
        const url = new URL(req.url, "http://localhost");
        let pathname = decodeURIComponent(url.pathname);

        let filePath;
        if (pathname === "/__lit/all.js") {
          filePath = join(__dirname, "vendor", "lit-all.js");
        } else if (pathname === "/" || pathname === "/__gate/page.html") {
          filePath = join(__dirname, "page.html");
        } else {
          filePath = join(ROOT, pathname);
        }

        // contain to allowed roots
        const norm = normalize(filePath);
        if (!norm.startsWith(ROOT) && !norm.startsWith(NODE_MODULES) && !norm.startsWith(__dirname)) {
          res.writeHead(403).end("forbidden");
          return;
        }

        const body = await tryRead(norm);
        if (body == null) {
          res.writeHead(404, { "content-type": "text/plain" }).end(`404 ${pathname}`);
          return;
        }
        res.writeHead(200, { "content-type": MIME[extname(norm)] || "application/octet-stream" });
        res.end(body);
      } catch (e) {
        res.writeHead(500, { "content-type": "text/plain" }).end(String(e));
      }
    });
    server.listen(port, "127.0.0.1", () => {
      const { port: p } = server.address();
      resolve({
        url: `http://127.0.0.1:${p}`,
        close: () => new Promise((r) => server.close(r)),
      });
    });
  });
}
