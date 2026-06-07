// The OQL kernel, embedded. oql.wasm (414 KB, the SAME component the Elixir
// runtime loads) is compiled into the shell and run via wasmtime — so the
// desktop app weaves/tangles/validates workbooks LOCALLY, with no Elixir server
// and no Docker. This is the workbook-native core: the app renders its own
// format. (The Elixir runtime stays the optional server tier for agents/sync.)
//
// The component's WIT world says "pure string→string", but the compiled artifact
// imports WASI 0.2 (Rust std), so we give it a WASI context with no preopens —
// render() never touches the filesystem.

use std::sync::OnceLock;
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{Config, Engine, Store};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiView};

static OQL_WASM: &[u8] = include_bytes!("../oql.wasm");
static ENGINE: OnceLock<Engine> = OnceLock::new();

struct Host {
    table: ResourceTable,
    wasi: WasiCtx,
}

impl WasiView for Host {
    fn table(&mut self) -> &mut ResourceTable {
        &mut self.table
    }
    fn ctx(&mut self) -> &mut WasiCtx {
        &mut self.wasi
    }
}

fn engine() -> &'static Engine {
    ENGINE.get_or_init(|| {
        let mut config = Config::new();
        config.wasm_component_model(true);
        Engine::new(&config).expect("wasmtime engine")
    })
}

/// Call a kernel export (`render` | `tangle-plan` | `validate` | `lint` |
/// `parse-headlines`) with one string arg, returning its string result.
pub fn call(export: &str, arg: &str) -> Result<String, String> {
    let engine = engine();
    let component = Component::from_binary(engine, OQL_WASM).map_err(s)?;

    let mut linker: Linker<Host> = Linker::new(engine);
    wasmtime_wasi::add_to_linker_sync(&mut linker).map_err(s)?;

    let host = Host {
        table: ResourceTable::new(),
        wasi: WasiCtxBuilder::new().build(),
    };
    let mut store = Store::new(engine, host);

    let instance = linker.instantiate(&mut store, &component).map_err(s)?;
    let func = instance
        .get_typed_func::<(String,), (String,)>(&mut store, export)
        .map_err(s)?;
    let (out,) = func.call(&mut store, (arg.to_string(),)).map_err(s)?;
    Ok(out)
}

/// Weave an Org workbook → rich HTML, locally.
pub fn weave(org: &str) -> Result<String, String> {
    call("render", org)
}

fn s(e: impl std::fmt::Display) -> String {
    e.to_string()
}

#[cfg(test)]
mod tests {
    // Proves the embedded kernel weaves Org → HTML with NO Elixir and NO Docker —
    // the workbook-native core, running purely in-process via wasmtime.
    #[test]
    fn weaves_org_to_html() {
        let html = super::weave("* Hello\n\nthe workbook renders itself\n").expect("weave");
        assert!(html.contains("Hello"), "expected heading text, got: {html}");
        assert!(html.contains('<'), "expected HTML markup, got: {html}");
    }
}

