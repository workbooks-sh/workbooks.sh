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

        // set a response header so the e2e exercises the NIF's response-header extraction path
        let fields = Fields::new();
        let _ = fields.append(&"x-brokered".to_string(), &b"yes".to_vec());

        let resp = OutgoingResponse::new(fields);
        let _ = resp.set_status_code(200);
        let body = resp.body().unwrap();
        ResponseOutparam::set(response_out, Ok(resp));
        let stream = body.write().unwrap();
        let msg = format!("hello from brokered guest; method={}", method);
        stream.blocking_write_and_flush(msg.as_bytes()).unwrap();
        drop(stream);
        let _ = OutgoingBody::finish(body, None);
    }
}

bindings::export!(Component with_types_in bindings);
