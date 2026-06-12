// wb-broker e2e guest: a wasi:http fetch probe. StarlingMonkey's fetch() routes through
// wasi:http/outgoing-handler -> our WasiHttpView::send_request override. Used to PROVE at runtime that
// the SSRF filter + allow-list actually fire: a fetch to an internal IP must be BLOCKED; an allowed
// public host must succeed. Componentize with @bytecodealliance/componentize-js, run via wasmex Components.
export async function probe(url) {
  try {
    const resp = await fetch(url, { method: "GET" });
    return "OK " + resp.status;
  } catch (e) {
    return "BLOCKED " + (e && e.message ? e.message : String(e));
  }
}
