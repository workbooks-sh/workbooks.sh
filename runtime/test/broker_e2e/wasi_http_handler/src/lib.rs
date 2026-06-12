#[allow(warnings)]
mod bindings;

use bindings::exports::wasi::http::incoming_handler::Guest;
use bindings::wasi::http::types::{
    Fields, IncomingRequest, OutgoingBody, OutgoingResponse, ResponseOutparam,
};

struct Component;

impl Guest for Component {
    fn handle(_request: IncomingRequest, response_out: ResponseOutparam) {
        let resp = OutgoingResponse::new(Fields::new());
        let _ = resp.set_status_code(200);
        let body = resp.body().unwrap();
        ResponseOutparam::set(response_out, Ok(resp));
        let stream = body.write().unwrap();
        stream.blocking_write_and_flush(b"hello from brokered guest").unwrap();
        drop(stream);
        let _ = OutgoingBody::finish(body, None);
    }
}

bindings::export!(Component with_types_in bindings);
