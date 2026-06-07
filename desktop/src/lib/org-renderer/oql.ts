// wb-i38o.9 — OQL WASM bridge for the WebView.
//
// Vendored at $lib/oql-wasm/ (web-target build from
// `substrates/oql/crates/oql-wasm`, generated via:
//
//   cd substrates/oql/crates/oql-wasm
//   wasm-pack build --target web --out-dir pkg-web --release
//
// then copying pkg-web/* into apps/desktop/src/lib/oql-wasm/).
//
// Vite resolves the bundled `oql_wasm_bg.wasm` URL at build time
// via the default export's URL-based init path. We init lazily — the
// first call to `getOql()` boots the module; subsequent calls
// return the same instance.

import init, {
  render_html,
  parse_headlines,
} from "$lib/oql-wasm/oql_wasm.js";
// Tell Vite to ship the .wasm as an asset and give us its URL. Vite
// rewrites `?url` imports to point at the hashed file in the output.
import wasmUrl from "$lib/oql-wasm/oql_wasm_bg.wasm?url";

export interface OqlApi {
  renderHtml: (src: string) => string;
  parseHeadlines: (src: string) => string;
}

let cached: Promise<OqlApi> | null = null;

export function getOql(): Promise<OqlApi> {
  if (!cached) {
    cached = init({ module_or_path: wasmUrl }).then(() => ({
      renderHtml: render_html,
      parseHeadlines: parse_headlines,
    }));
  }
  return cached;
}
