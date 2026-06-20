// eval-host bootstrap: bind the toolkit-caps WIT imports to __cap_* globals, then run(input)=eval.
// Componentized to priv/eval-host.wasm via jco componentize (see README.md).
import { store, load, emit, cacheGet, cachePut, cacheDelete, fetch as capFetch, complete } from 'work:evalhost/toolkit-caps';
globalThis.__cap_store = store;
globalThis.__cap_load = load;
globalThis.__cap_emit = emit;
globalThis.__cap_cache_get = cacheGet;
globalThis.__cap_cache_put = cachePut;
globalThis.__cap_cache_delete = cacheDelete;
globalThis.__cap_fetch = capFetch;
globalThis.__cap_complete = complete;
export function run(input) { return String(eval(input)); }
