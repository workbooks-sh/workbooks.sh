use rustler::{Binary, Error, NifStruct, OwnedBinary, Resource, ResourceArc};
use std::ops::Deref;
use std::sync::{LazyLock, Mutex};
use wasmtime::{Config, Engine, WasmBacktraceDetails};

use crate::atoms;

pub static TOKIO_RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    // Spawn <number of CPU cores> OS threads, fall back to `8` if detection fails
    let num_threads = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(8);

    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(num_threads)
        .thread_name("wasmex-async")
        .enable_all()
        .build()
        .expect("Failed to create Tokio runtime")
});

#[derive(NifStruct)]
#[module = "Wasmex.EngineConfig"]
pub struct ExEngineConfig {
    consume_fuel: bool,
    wasm_backtrace_details: bool,
    cranelift_opt_level: rustler::Atom,
    memory64: bool,
    wasm_component_model: bool,
    debug_info: bool,
    // wb-broker (wb-95o6): enable epoch interruption + a 1s ticker so the serve path can wall-clock-bound a
    // guest deadlocked on write-backpressure (large response body) via set_epoch_deadline, instead of hanging.
    epoch_interruption: bool,
}

#[rustler::resource_impl()]
impl Resource for EngineResource {}

pub struct EngineResource {
    pub inner: Mutex<Engine>,
    // wb-9jqy: whether this engine was built with epoch_interruption. A store on such an engine MUST
    // be given an epoch deadline before any wasm runs (default deadline 0 traps immediately, even at
    // instantiation), so component_store_new arms a generous initial deadline when this is true.
    pub epoch: bool,
}

#[rustler::nif(name = "engine_new")]
pub fn new(
    engine_config_ex: ExEngineConfig,
) -> Result<ResourceArc<EngineResource>, rustler::Error> {
    let epoch = engine_config_ex.epoch_interruption;
    let config = engine_config(engine_config_ex);
    let engine = Engine::new(&config).map_err(|err| Error::Term(Box::new(err.to_string())))?;

    // wb-95o6: a 1s epoch ticker. Holds only a WEAK ref so it stops when the engine is dropped — no leak.
    // A store on this engine can `set_epoch_deadline(N)` to trap a call after ~N seconds of wall-clock.
    if epoch {
        let weak = engine.weak();
        std::thread::Builder::new()
            .name("wasmex-epoch".into())
            .spawn(move || loop {
                match weak.upgrade() {
                    Some(e) => {
                        e.increment_epoch();
                        drop(e);
                        std::thread::sleep(std::time::Duration::from_secs(1));
                    }
                    None => break,
                }
            })
            .ok();
    }

    let resource = ResourceArc::new(EngineResource {
        inner: Mutex::new(engine),
        epoch,
    });

    Ok(resource)
}

#[rustler::nif(name = "engine_precompile_module", schedule = "DirtyCpu")]
pub fn precompile_module<'a>(
    env: rustler::Env<'a>,
    engine_resource: ResourceArc<EngineResource>,
    binary: Binary<'a>,
) -> Result<Binary<'a>, rustler::Error> {
    let engine: &Engine = &*(engine_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!("Could not unlock engine resource: {e}")))
    })?);
    let bytes = binary.as_slice();
    let serialized_module = engine.precompile_module(bytes).map_err(|err| {
        rustler::Error::Term(Box::new(format!("Could not precompile module: {err}")))
    })?;
    let mut binary = OwnedBinary::new(serialized_module.len())
        .ok_or_else(|| rustler::Error::Term(Box::new("not enough memory")))?;
    binary.copy_from_slice(&serialized_module);
    Ok(binary.release(env))
}

pub(crate) fn engine_config(engine_config: ExEngineConfig) -> Config {
    let backtrace_details = match engine_config.wasm_backtrace_details {
        true => WasmBacktraceDetails::Enable,
        false => WasmBacktraceDetails::Disable,
    };
    let cranelift_opt_level = if engine_config.cranelift_opt_level == atoms::speed() {
        wasmtime::OptLevel::Speed
    } else if engine_config.cranelift_opt_level == atoms::speed_and_size() {
        wasmtime::OptLevel::SpeedAndSize
    } else {
        wasmtime::OptLevel::None
    };

    let mut config = Config::new();
    config.consume_fuel(engine_config.consume_fuel);
    config.wasm_backtrace_details(backtrace_details);
    config.cranelift_opt_level(cranelift_opt_level);
    config.wasm_memory64(engine_config.memory64);
    config.wasm_component_model(engine_config.wasm_component_model);
    config.debug_info(engine_config.debug_info);
    // wb-v3d: enable the wasm exception-handling proposal so mrustc_pm.wasm (C++ EH → exnref) can
    // run under Wasmex. exnref rides on function-references; enable both.
    config.wasm_function_references(true);
    config.wasm_exceptions(true);
    // wb-95o6: epoch interruption (off by default). When on, the engine's epoch is ticked once a second and
    // a store can set_epoch_deadline; reaching it traps the running call (used to bound a deadlocked serve).
    config.epoch_interruption(engine_config.epoch_interruption);

    config
}

pub(crate) fn unwrap_engine(
    engine_resource: ResourceArc<EngineResource>,
) -> Result<Engine, rustler::Error> {
    let engine: Engine = engine_resource
        .deref()
        .inner
        .lock()
        .map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock engine resource as the mutex was poisoned: {e}"
            )))
        })?
        .clone();
    Ok(engine)
}
