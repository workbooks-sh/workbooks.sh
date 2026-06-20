// eval-host bootstrap — converged on the shared host-broker seam (wb:jseval/broker.host-call).
// Bind the single synchronous host-call import to globalThis.__wbHostCall so RUNTIME-eval'd code
// (toolkit $host shims, node-compat shims — all under classic eval, no ESM import) can reach it.
// run(input) evals + awaits. Matches runtime/host/js_engine.ex so the staged engine is interchangeable.
import { hostCall } from 'wb:jseval/broker';
globalThis.__wbHostCall = hostCall;
export async function run(src) {
  try {
    let r = (0, eval)(src);
    if (r && typeof r.then === "function") r = await r;
    if (r === undefined) return "undefined";
    if (typeof r === "object" && r !== null) { try { return JSON.stringify(r); } catch (_) { return String(r); } }
    return String(r);
  } catch (e) { return "ERR: " + (e && e.message ? e.message : String(e)); }
}
