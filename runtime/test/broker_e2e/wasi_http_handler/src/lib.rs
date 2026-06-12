#[allow(warnings)]
mod bindings;

use bindings::exports::wasi::http::incoming_handler::Guest;
use bindings::wasi::http::types::{
    Fields, IncomingRequest, OutgoingBody, OutgoingResponse, ResponseOutparam,
};

struct Component;

impl Guest for Component {
    fn handle(request: IncomingRequest, response_out: ResponseOutparam) {
        // echo the request method back so the e2e can prove the request data reached the guest
        let method = format!("{:?}", request.method());

        // SSRF-COMPOSITION probe: a (red-team) serving guest tries an OUTBOUND fetch to cloud metadata while
        // handling a request. It MUST go through the host's brokered send_request and be SSRF-blocked — a
        // serving guest must not become an SSRF pivot.
        let outbound = probe_metadata();

        // set a response header so the e2e exercises the NIF's response-header extraction path
        let fields = Fields::new();
        let _ = fields.append(&"x-brokered".to_string(), &b"yes".to_vec());

        let resp = OutgoingResponse::new(fields);
        let _ = resp.set_status_code(200);
        let body = resp.body().unwrap();
        ResponseOutparam::set(response_out, Ok(resp));
        let stream = body.write().unwrap();
        let msg = format!("hello from brokered guest; method={}; outbound={}", method, outbound);
        stream.blocking_write_and_flush(msg.as_bytes()).unwrap();
        drop(stream);
        let _ = OutgoingBody::finish(body, None);
    }
}

// Attempt an outbound HTTP GET to cloud metadata (169.254.169.254). Returns "blocked" when the host's
// SSRF broker denies it (the expected, secure outcome) or "REACHED" if it somehow succeeded.
fn probe_metadata() -> String {
    use bindings::wasi::http::outgoing_handler;
    use bindings::wasi::http::types::{Method, OutgoingRequest, Scheme};

    let req = OutgoingRequest::new(Fields::new());
    let _ = req.set_method(&Method::Get);
    let _ = req.set_scheme(Some(&Scheme::Http));
    let _ = req.set_authority(Some("169.254.169.254"));
    let _ = req.set_path_with_query(Some("/"));

    match outgoing_handler::handle(req, None) {
        Ok(future) => {
            future.subscribe().block();
            match future.get() {
                Some(Ok(Ok(_resp))) => "REACHED".to_string(),
                _ => "blocked".to_string(),
            }
        }
        Err(_) => "blocked".to_string(),
    }
}

bindings::export!(Component with_types_in bindings);
