// wb-broker reclamation proof: a real wasi:http "fetch" tool — retrieves the BODY of a URL through the
// brokered (SSRF-filtered) outbound path. This is the curl/httpie capability, reclaimed for STANDARD
// wasi:http guests by the wb-0beq fix. Componentize with jco; run via wasmex Components with allow_http.
export async function probe(url) {
  try {
    const resp = await fetch(url, { method: "GET" });
    const body = await resp.text();
    return "OK:" + body.slice(0, 300);
  } catch (e) {
    return "BLOCKED " + (e && e.message ? e.message : String(e));
  }
}
