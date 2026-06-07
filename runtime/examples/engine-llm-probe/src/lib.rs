//! A Workbook component that calls the LLM through the Dock. `run(prompt)` asks
//! the model (host holds the key) and returns its reply — proving a WASM
//! component can do LLM work without seeing the credential.
#[allow(warnings)]
mod bindings;
use bindings::Guest;
struct Probe;
impl Guest for Probe {
    fn run(input: String) -> String {
        let reply = bindings::llm_complete(&format!("In 5 words or fewer: {}", input));
        format!("{{\"asked\":\"{}\",\"llm\":\"{}\"}}", input, reply.replace('"', "'"))
    }
}
bindings::export!(Probe with_types_in bindings);
