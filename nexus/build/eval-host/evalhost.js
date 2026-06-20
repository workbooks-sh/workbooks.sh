// eval-host bootstrap: bind toolkit-caps WIT imports to __cap_* globals; run(input) evals and
// awaits (StarlingMonkey drains the event loop) so async harnesses (js_dom) resolve before return.
import { store, load, emit, cacheGet, cachePut, cacheDelete, fetch as capFetch, complete } from 'work:evalhost/toolkit-caps';
globalThis.__cap_store = store;
globalThis.__cap_load = load;
globalThis.__cap_emit = emit;
globalThis.__cap_cache_get = cacheGet;
globalThis.__cap_cache_put = cachePut;
globalThis.__cap_cache_delete = cacheDelete;
globalThis.__cap_fetch = capFetch;
globalThis.__cap_complete = complete;
export async function run(input) {
  let r = (0, eval)(input);
  if (r && typeof r.then === "function") r = await r;
  return String(r);
}
