use std::collections::HashMap;
use std::sync::{Condvar, Mutex};

use rustler::env::SavedTerm;
use wit_parser::{Function, Resolve, WorldItem};

use crate::atoms;
use crate::component::ComponentResource;
use crate::engine::TOKIO_RUNTIME;
use crate::store::ComponentStoreData;
use crate::store::ComponentStoreResource;
use rustler::types::tuple::make_tuple;
use rustler::NifResult;
use rustler::ResourceArc;
use rustler::{Encoder, OwnedEnv};
use rustler::{Error, LocalPid};
use wasmtime::component::{Instance, Linker, LinkerInstance, Type, Val};
use wasmtime::Trap;
use wiggle::anyhow::{self};

use rustler::Term;

use wasmtime::Store;

use wasmtime_wasi;
use wasmtime_wasi_http;

use crate::component_type_conversion::{
    convert_params, convert_result_term, encode_result, vals_to_terms,
};

pub struct ComponentCallbackToken {
    pub continue_signal: Condvar,
    pub name: String,
    pub namespace: Option<String>,
    pub return_values: Mutex<Option<(bool, Vec<Val>)>>,
}

pub struct ComponentCallbackTokenResource {
    pub token: ComponentCallbackToken,
}

#[rustler::resource_impl()]
impl rustler::Resource for ComponentCallbackTokenResource {}

pub struct ComponentInstanceResource {
    pub inner: Mutex<Instance>,
}

#[rustler::resource_impl()]
impl rustler::Resource for ComponentInstanceResource {}

#[rustler::nif(name = "component_instance_new")]
pub fn new_instance(
    store_resource: ResourceArc<ComponentStoreResource>,
    component_resource: ResourceArc<ComponentResource>,
    imports: rustler::Term,
) -> NifResult<ResourceArc<ComponentInstanceResource>> {
    let store: &mut Store<ComponentStoreData> =
        &mut *(store_resource.inner.lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!(
                "Could not unlock store resource as the mutex was poisoned: {e}"
            )))
        })?);

    let component = component_resource.inner.lock().map_err(|e| {
        rustler::Error::Term(Box::new(format!(
            "Could not unlock component resource as the mutex was poisoned: {e}"
        )))
    })?;

    let mut linker = Linker::new(store.engine());
    linker.allow_shadowing(true);
    let _ = wasmtime_wasi::p2::add_to_linker_sync(&mut linker);
    if store.data().http.is_some() {
        let _ = wasmtime_wasi_http::add_only_http_to_linker_sync(&mut linker);
    }

    // Instantiate the component

    // Handle imports
    let imports_map = imports.decode::<HashMap<String, Term>>()?;
    for (name, implementation) in imports_map {
        if Term::is_tuple(implementation) {
            // root imports
            link_import(&mut linker.root(), name, None, implementation)?;
        } else {
            let imports_map = implementation.decode::<HashMap<String, Term>>()?;
            let mut namespace = linker
                .instance(&name)
                .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;
            for (implementation_name, implementation) in imports_map {
                link_import(
                    &mut namespace,
                    implementation_name,
                    Some(name.clone()),
                    implementation,
                )?;
            }
        }
    }

    let instance = linker
        .instantiate(&mut *store, &component)
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))?;

    Ok(ResourceArc::new(ComponentInstanceResource {
        inner: Mutex::new(instance),
    }))
}

fn create_callback_token(
    name: String,
    namespace: Option<String>,
) -> ResourceArc<ComponentCallbackTokenResource> {
    ResourceArc::new(ComponentCallbackTokenResource {
        token: ComponentCallbackToken {
            continue_signal: Condvar::new(),
            name,
            namespace,
            return_values: Mutex::new(None),
        },
    })
}

fn call_elixir_import(
    name: String,
    namespace: Option<String>,
    params: &[Val],
    result_values: &mut [Val],
    pid: LocalPid,
) -> Result<(), anyhow::Error> {
    let mut msg_env = OwnedEnv::new();
    let callback_token = create_callback_token(name.clone(), namespace.clone());

    let _ = msg_env.send_and_clear(&pid, |env| {
        let param_terms = vals_to_terms(params, env);
        (
            atoms::invoke_callback(),
            namespace,
            name,
            callback_token.clone(),
            param_terms,
        )
    });

    let mut result = callback_token.token.return_values.lock().unwrap();
    while result.is_none() {
        result = callback_token.token.continue_signal.wait(result).unwrap();
    }

    let (success, returned_values) = result.take().unwrap();
    if !success {
        return Err(anyhow::anyhow!("Callback failed"));
    }

    if !returned_values.is_empty() {
        result_values[0] = returned_values[0].clone();
    }
    Ok(())
}

fn link_import(
    linker_instance: &mut LinkerInstance<ComponentStoreData>,
    name: String,
    namespace: Option<String>,
    implementation: Term,
) -> NifResult<()> {
    let pid = implementation.get_env().pid();
    let name_for_closure = name.clone();

    linker_instance
        .func_new(
            &name,
            move |_store, _function_type, params, result_values| {
                call_elixir_import(
                    name_for_closure.clone(),
                    namespace.clone(),
                    params,
                    result_values,
                    pid,
                )
            },
        )
        .map_err(|e| rustler::Error::Term(Box::new(e.to_string())))
}

#[rustler::nif(name = "component_call_function")]
pub fn call_exported_function(
    component_store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    function_name_path: Vec<String>,
    given_params: Term,
    from: Term,
) -> rustler::Atom {
    // create erlang environment for the thread
    let mut thread_env = OwnedEnv::new();
    // copy over params into the thread environment
    let function_params = thread_env.save(given_params);
    let from = thread_env.save(from);

    // wb-broker (wb-0beq): run the SYNC component call on a BLOCKING thread, not a tokio worker. The body
    // has no .await; via spawn_blocking a wasi-http OUTBOUND call's internal `in_tokio`/block_on
    // (wasmtime-wasi) finds NO current runtime handle and spins up its own — instead of panicking "Cannot
    // start a runtime from within a runtime" when called from a worker. Unblocks wasi-http outbound (proven:
    // a guest fetched a public URL -> HTTP 301, while SSRF still blocks internal) WITHOUT the engine-wide
    // async_support refactor; sync call() is unchanged.
    TOKIO_RUNTIME.spawn_blocking(move || {
        // Execute function and get the result
        let result = component_execute_function(
            &mut thread_env,
            component_store_resource,
            instance_resource,
            function_name_path,
            function_params,
        );

        // Send result directly to the caller
        thread_env.run(|env| {
            let from_tuple = from.load(env).decode::<Term>().unwrap();
            let result_term = result
                .load(env)
                .decode::<Term>()
                .unwrap_or(atoms::error().encode(env));

            // GenServer.call from tuple is {pid, ref}
            // LocalPid in Rustler can handle both local and remote PIDs (despite the name)
            let (caller_pid, ref_term) = from_tuple
                .decode::<(LocalPid, Term)>()
                .expect("from must be a GenServer {pid, ref} tuple");

            // Send GenServer reply format directly to caller: {ref, result}
            let _ = env.send(&caller_pid, make_tuple(env, &[ref_term, result_term]));
        });
    });

    atoms::ok()
}

// wb-broker INBOUND standard-component seam (wb-py4k): drive a guest that exports wasi:http/incoming-handler.
// The host synthesizes the request, calls handle (SYNC — the engine is sync), and collects the response the
// guest writes to the response-outparam. Lets STANDARD wasi:http server components run as sandboxed guests.
#[rustler::nif(name = "component_serve_http", schedule = "DirtyCpu")]
pub fn serve_http<'a>(
    env: rustler::Env<'a>,
    component_store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    method: String,
    uri: String,
    headers: Vec<(String, String)>,
    body: rustler::Binary,
    epoch_deadline_secs: u64,
) -> NifResult<(u16, Vec<(String, String)>, rustler::Binary<'a>)> {
    use bytes::Bytes;
    use http_body::Body;
    use http_body_util::{BodyExt, Full};
    use rustler::OwnedBinary;
    use wasmtime_wasi_http::bindings::http::types::Scheme;
    use wasmtime_wasi_http::WasiHttpView;

    // DoS floor (huge bodies): cap the response body the host will buffer from the guest — a malicious
    // hosted app can't exhaust host memory by returning an unbounded body.
    const MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;

    // SETUP under the store/instance locks; released at the end of the block so the handler thread can take
    // the store (see serve_http_stream for the full concurrent-drain rationale).
    let (handle, req_any, out_any, rx) = {
        let mut store_guard = component_store_resource.inner.lock().unwrap();
        let store: &mut Store<ComponentStoreData> = &mut store_guard;
        let mut instance_guard = instance_resource.inner.lock().unwrap();
        let instance = &mut *instance_guard;

        let mut builder = hyper::Request::builder()
            .method(method.as_str())
            .uri(uri.as_str());
        for (k, v) in &headers {
            builder = builder.header(k.as_str(), v.as_str());
        }
        let req_body = Full::new(Bytes::copy_from_slice(body.as_slice()))
            .map_err(|e: std::convert::Infallible| match e {})
            .boxed();
        let hyper_req = builder
            .body(req_body)
            .map_err(|e| Error::Term(Box::new(e.to_string())))?;

        let req = store
            .data_mut()
            .new_incoming_request(Scheme::Http, hyper_req)
            .map_err(|e| Error::Term(Box::new(e.to_string())))?;
        let (tx, rx) = tokio::sync::oneshot::channel();
        let out = store
            .data_mut()
            .new_response_outparam(tx)
            .map_err(|e| Error::Term(Box::new(e.to_string())))?;

        let mut iface = None;
        for name in [
            "wasi:http/incoming-handler@0.2.6",
            "wasi:http/incoming-handler@0.2.3",
            "wasi:http/incoming-handler@0.2.0",
            "wasi:http/incoming-handler",
        ] {
            if let Some((_, idx)) = instance.get_export(&mut *store, None, name) {
                iface = Some(idx);
                break;
            }
        }
        let iface = iface
            .ok_or_else(|| Error::Term(Box::new("no wasi:http/incoming-handler export".to_string())))?;
        let handle_idx = instance
            .get_export(&mut *store, Some(&iface), "handle")
            .map(|(_, idx)| idx)
            .ok_or_else(|| Error::Term(Box::new("no #handle export".to_string())))?;
        let handle = instance
            .get_func(&mut *store, handle_idx)
            .ok_or_else(|| Error::Term(Box::new("handle is not a func".to_string())))?;

        let req_any = req
            .try_into_resource_any(&mut *store)
            .map_err(|e| Error::Term(Box::new(e.to_string())))?;
        let out_any = out
            .try_into_resource_any(&mut *store)
            .map_err(|e| Error::Term(Box::new(e.to_string())))?;

        (handle, req_any, out_any, rx)
    };

    // wb-95o6 FIX: run handle() on a blocking thread while THIS thread drains the response body, so a body
    // larger than the wasi-http buffer can't deadlock the guest on write-backpressure (the old call-then-read
    // bug). The drain reads the decoupled body channel (no store lock) so it never contends with the handler.
    let store_arc = component_store_resource.clone();
    let handle_task = TOKIO_RUNTIME.spawn_blocking(move || {
        let mut g = store_arc.inner.lock().unwrap();
        let store: &mut Store<ComponentStoreData> = &mut g;
        // wb-95o6 (compute-DoS): bound a guest spinning in handle() — epoch traps the running wasm at the
        // deadline, freeing this worker thread (requires an epoch_interruption engine; caller passes 0 else).
        if epoch_deadline_secs > 0 {
            store.set_epoch_deadline(epoch_deadline_secs);
        }
        match handle.call(
            &mut *store,
            &[Val::Resource(req_any), Val::Resource(out_any)],
            &mut [],
        ) {
            Ok(()) => {
                let _ = handle.post_return(&mut *store);
                Ok(())
            }
            Err(e) => Err(e.to_string()),
        }
    });

    // a guest spinning BEFORE it sets the response is trapped by epoch (frees the worker), but its response
    // sender lingers in the store so rx never resolves — bound this wait too when a deadline is set.
    let resp = if epoch_deadline_secs > 0 {
        match TOKIO_RUNTIME.block_on(async {
            tokio::time::timeout(
                std::time::Duration::from_secs(epoch_deadline_secs + 5),
                rx,
            )
            .await
        }) {
            Ok(Ok(Ok(resp))) => resp,
            Ok(Ok(Err(e))) => return Err(Error::Term(Box::new(format!("response error: {e:?}")))),
            Ok(Err(e)) => return Err(Error::Term(Box::new(format!("guest set no response: {e}")))),
            Err(_) => {
                return Err(Error::Term(Box::new(
                    "wb-broker: serve response timed out (guest stuck)".to_string(),
                )))
            }
        }
    } else {
        TOKIO_RUNTIME
            .block_on(rx)
            .map_err(|e| Error::Term(Box::new(format!("guest set no response: {e}"))))?
            .map_err(|e| Error::Term(Box::new(format!("response error: {e:?}"))))?
    };
    let (parts, mut resp_body) = resp.into_parts();

    // drain into a buffer capped at MAX_RESPONSE_BYTES, but KEEP draining past the cap (discarding) so the
    // guest never blocks on a full channel (no leak); error only once the stream closes if it exceeded the cap.
    let mut buf: Vec<u8> = Vec::new();
    let mut over = false;
    loop {
        match TOKIO_RUNTIME.block_on(async { resp_body.frame().await }) {
            Some(Ok(frame)) => {
                if let Ok(bytes) = frame.into_data() {
                    if buf.len() + bytes.len() <= MAX_RESPONSE_BYTES {
                        buf.extend_from_slice(&bytes);
                    } else {
                        over = true;
                    }
                }
            }
            _ => break,
        }
    }
    let _ = TOKIO_RUNTIME.block_on(handle_task);
    if over {
        return Err(Error::Term(Box::new(
            "wb-broker: response body exceeds cap".to_string(),
        )));
    }
    let body_bytes = Bytes::from(buf);

    // hand the body back as a binary (no intermediate byte-list) so real HTTP payloads stay efficient
    let mut out_bin = OwnedBinary::new(body_bytes.len())
        .ok_or_else(|| Error::Term(Box::new("response body alloc failed".to_string())))?;
    out_bin.as_mut_slice().copy_from_slice(&body_bytes);

    let out_headers = parts
        .headers
        .iter()
        .map(|(k, v)| {
            (
                k.as_str().to_string(),
                String::from_utf8_lossy(v.as_bytes()).to_string(),
            )
        })
        .collect::<Vec<_>>();

    Ok((parts.status.as_u16(), out_headers, out_bin.release(env)))
}

// wb-broker STREAMING inbound serve (wb-t3sq): same as serve_http, but instead of buffering the response
// body it streams it FRAME-BY-FRAME to `caller` as messages tagged with `ref_term`:
//   {ref, :stream_start, status, headers} ; {ref, :stream_data, <binary>}* ; {ref, :stream_done}
// The Plug spawns this (so it isn't blocked in the NIF) and forwards each chunk via send_chunked. Enables
// large downloads / Server-Sent-Events / big responses without the host buffering the whole body.
#[rustler::nif(name = "component_serve_http_stream", schedule = "DirtyCpu")]
pub fn serve_http_stream(
    env: rustler::Env,
    component_store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    method: String,
    uri: String,
    headers: Vec<(String, String)>,
    body: rustler::Binary,
    caller: rustler::LocalPid,
    ref_term: rustler::Term,
    epoch_deadline_secs: u64,
) -> NifResult<rustler::Atom> {
    use bytes::Bytes;
    use http_body::Body;
    use http_body_util::{BodyExt, Full};
    use rustler::OwnedBinary;
    use wasmtime_wasi_http::bindings::http::types::Scheme;
    use wasmtime_wasi_http::WasiHttpView;

    // SETUP under the store/instance locks: synthesize the request, register the response outparam (rx
    // receives the response the instant the guest calls ResponseOutparam::set — EARLY in handle(), before it
    // writes the body), and resolve the handler. The locks are released at the end of this block so the
    // handler thread (below) can take the store.
    let (handle, req_any, out_any, rx) = {
        let mut store_guard = component_store_resource.inner.lock().unwrap();
        let store: &mut Store<ComponentStoreData> = &mut store_guard;
        let mut instance_guard = instance_resource.inner.lock().unwrap();
        let instance = &mut *instance_guard;

        let mut builder = hyper::Request::builder()
            .method(method.as_str())
            .uri(uri.as_str());
        for (k, v) in &headers {
            builder = builder.header(k.as_str(), v.as_str());
        }
        let req_body = Full::new(Bytes::copy_from_slice(body.as_slice()))
            .map_err(|e: std::convert::Infallible| match e {})
            .boxed();
        let hyper_req = builder
            .body(req_body)
            .map_err(|e| Error::Term(Box::new(e.to_string())))?;

        let req = store
            .data_mut()
            .new_incoming_request(Scheme::Http, hyper_req)
            .map_err(|e| Error::Term(Box::new(e.to_string())))?;
        let (tx, rx) = tokio::sync::oneshot::channel();
        let out = store
            .data_mut()
            .new_response_outparam(tx)
            .map_err(|e| Error::Term(Box::new(e.to_string())))?;

        let mut iface = None;
        for name in [
            "wasi:http/incoming-handler@0.2.6",
            "wasi:http/incoming-handler@0.2.3",
            "wasi:http/incoming-handler@0.2.0",
            "wasi:http/incoming-handler",
        ] {
            if let Some((_, idx)) = instance.get_export(&mut *store, None, name) {
                iface = Some(idx);
                break;
            }
        }
        let iface = iface
            .ok_or_else(|| Error::Term(Box::new("no wasi:http/incoming-handler export".to_string())))?;
        let handle_idx = instance
            .get_export(&mut *store, Some(&iface), "handle")
            .map(|(_, idx)| idx)
            .ok_or_else(|| Error::Term(Box::new("no #handle export".to_string())))?;
        let handle = instance
            .get_func(&mut *store, handle_idx)
            .ok_or_else(|| Error::Term(Box::new("handle is not a func".to_string())))?;

        let req_any = req
            .try_into_resource_any(&mut *store)
            .map_err(|e| Error::Term(Box::new(e.to_string())))?;
        let out_any = out
            .try_into_resource_any(&mut *store)
            .map_err(|e| Error::Term(Box::new(e.to_string())))?;

        (handle, req_any, out_any, rx)
    };

    // wb-95o6 FIX: run handle() on a SEPARATE blocking thread while THIS thread drains the response body
    // concurrently. The old code called handle() to COMPLETION then read the body — so a guest writing a body
    // larger than the wasi-http output buffer blocked forever on write-backpressure (nobody was draining),
    // deadlocking and leaking the thread. Now the handler fills the response-body channel and we drain it as
    // it fills, so the guest's writes always make progress. The store is re-locked only inside the handler
    // thread; the body drain reads the decoupled body channel (no store lock), so the two never contend.
    let store_arc = component_store_resource.clone();
    let handle_task = TOKIO_RUNTIME.spawn_blocking(move || {
        let mut g = store_arc.inner.lock().unwrap();
        let store: &mut Store<ComponentStoreData> = &mut g;
        // wb-95o6 (compute-DoS): bound a guest that SPINS in handle() (e.g. an infinite wasm loop before it
        // sets the response). Epoch CAN trap running wasm (unlike the backpressure case); reaching the
        // deadline traps the call, handle() returns Err, the response sender drops, and rx unblocks below.
        // Requires an epoch_interruption engine (else set_epoch_deadline panics) — caller passes 0 otherwise.
        if epoch_deadline_secs > 0 {
            store.set_epoch_deadline(epoch_deadline_secs);
        }
        match handle.call(
            &mut *store,
            &[Val::Resource(req_any), Val::Resource(out_any)],
            &mut [],
        ) {
            Ok(()) => {
                let _ = handle.post_return(&mut *store);
                Ok(())
            }
            Err(e) => Err(e.to_string()),
        }
    });

    // the guest set the response EARLY (before the body); receive it, then stream the body live. When an
    // epoch deadline is set (compute-DoS guard), ALSO bound this wait: a guest spinning before it sets the
    // response is trapped by epoch (frees the worker thread) but its response sender lingers in the store, so
    // rx would never resolve — the timeout (deadline + margin) frees THIS thread.
    let resp = if epoch_deadline_secs > 0 {
        match TOKIO_RUNTIME.block_on(async {
            tokio::time::timeout(
                std::time::Duration::from_secs(epoch_deadline_secs + 5),
                rx,
            )
            .await
        }) {
            Ok(Ok(Ok(resp))) => resp,
            Ok(Ok(Err(e))) => return Err(Error::Term(Box::new(format!("response error: {e:?}")))),
            Ok(Err(e)) => return Err(Error::Term(Box::new(format!("guest set no response: {e}")))),
            Err(_) => {
                return Err(Error::Term(Box::new(
                    "wb-broker: serve response timed out (guest stuck)".to_string(),
                )))
            }
        }
    } else {
        TOKIO_RUNTIME
            .block_on(rx)
            .map_err(|e| Error::Term(Box::new(format!("guest set no response: {e}"))))?
            .map_err(|e| Error::Term(Box::new(format!("response error: {e:?}"))))?
    };
    let (parts, mut resp_body) = resp.into_parts();

    let out_headers = parts
        .headers
        .iter()
        .map(|(k, v)| {
            (
                k.as_str().to_string(),
                String::from_utf8_lossy(v.as_bytes()).to_string(),
            )
        })
        .collect::<Vec<_>>();

    let start = rustler::Atom::from_str(env, "stream_start").unwrap();
    let data = rustler::Atom::from_str(env, "stream_data").unwrap();
    let done = rustler::Atom::from_str(env, "stream_done").unwrap();

    let _ = env.send(
        &caller,
        (ref_term, start, parts.status.as_u16(), out_headers).encode(env),
    );

    // drain the body frame by frame — CONCURRENT with the handler thread writing it (no deadlock)
    loop {
        match TOKIO_RUNTIME.block_on(async { resp_body.frame().await }) {
            Some(Ok(frame)) => {
                if let Ok(bytes) = frame.into_data() {
                    let mut bin = OwnedBinary::new(bytes.len()).unwrap();
                    bin.as_mut_slice().copy_from_slice(&bytes);
                    let _ = env.send(&caller, (ref_term, data, bin.release(env)).encode(env));
                }
            }
            _ => break,
        }
    }

    let _ = env.send(&caller, (ref_term, done).encode(env));
    let _ = TOKIO_RUNTIME.block_on(handle_task);
    Ok(rustler::Atom::from_str(env, "ok").unwrap())
}

fn component_execute_function(
    thread_env: &mut OwnedEnv,
    component_store_resource: ResourceArc<ComponentStoreResource>,
    instance_resource: ResourceArc<ComponentInstanceResource>,
    function_name_path: Vec<String>,
    function_params: SavedTerm,
) -> SavedTerm {
    let result = thread_env.run(|env| {
        let component_store: &mut Store<ComponentStoreData> =
            &mut (component_store_resource.inner.lock().unwrap());
        let instance = &mut instance_resource.inner.lock().unwrap();

        let given_params = match function_params.load(env).decode::<Vec<Term>>() {
            Ok(vec) => vec,
            Err(err) => {
                return env
                    .error_tuple(format!("could not load 'function params': {err:?}"))
                    .encode(env)
            }
        };

        // reduce function_name_path to a lookup index by iterating over function_name_path and calling instance.get_export
        let mut lookup_index = None;
        for (index, name) in function_name_path.iter().enumerate() {
            if let Some(inner) = lookup_index {
                lookup_index = instance
                    .get_export(&mut *component_store, Some(&inner), name.as_str())
                    .map(|(_, index)| index);
            } else {
                lookup_index = instance
                    .get_export(&mut *component_store, None, name.as_str())
                    .map(|(_, index)| index);
            }

            if lookup_index.is_none() {
                if function_name_path.len() == 1 {
                    return env
                        .error_tuple(format!(
                            "exported function `{}` not found.",
                            function_name_path.join(", ")
                        ))
                        .encode(env);
                } else {
                    return env
                        .error_tuple(format!(
                        "exported function `[{}]` not found. Could not find `{}` at position {}",
                        function_name_path.join(", "),
                        name,
                        index
                    ))
                        .encode(env);
                }
            }
        }

        let lookup_index = match lookup_index {
            Some(index) => index,
            None => {
                return env
                    .error_tuple(format!(
                        "exported function `{}` not found.",
                        function_name_path.join(", ")
                    ))
                    .encode(env);
            }
        };

        let function_result = instance.get_func(&mut *component_store, lookup_index);
        let function = match function_result {
            Some(func) => func,
            None => {
                return env
                    .error_tuple(format!(
                        "exported function `{}` not found",
                        function_name_path.join(", ")
                    ))
                    .encode(env)
            }
        };

        let function_type = function.ty(&component_store);
        let param_types = function_type.params();
        let param_types = param_types.map(|x| x.1.clone()).collect::<Vec<Type>>();

        let converted_params = match convert_params(param_types.as_ref(), given_params) {
            Ok(params) => params,
            Err(Error::Term(e)) => {
                return env.error_tuple(e.encode(env)).encode(env);
            }
            Err(e) => {
                let reason = format!("Error converting param: {e:?}");
                return env.error_tuple(&reason).encode(env);
            }
        };
        let results_count = function_type.results().len();

        let mut result = vec![Val::Bool(false); results_count];
        match function.call(
            &mut *component_store,
            converted_params.as_slice(),
            &mut result,
        ) {
            Ok(_) => {
                let _ = function.post_return(&mut *component_store);
                encode_result(env, result)
            }
            Err(err) => {
                let reason = format!("{err}");
                if let Ok(trap) = err.downcast::<Trap>() {
                    env.error_tuple(format!(
                        "Error during function excecution ({trap}): {reason}"
                    ))
                } else {
                    env.error_tuple(format!("Error during function excecution: {reason}"))
                }
            }
        }
        .encode(env)
    });
    thread_env.save(result)
}

#[rustler::nif(name = "component_receive_callback_result")]
pub fn receive_callback_result(
    component_resource: ResourceArc<ComponentResource>,
    token_resource: ResourceArc<ComponentCallbackTokenResource>,
    _success: bool,
    result: Term,
) -> NifResult<rustler::Atom> {
    let parsed_component = &component_resource.parsed;
    let world = &parsed_component.resolve.worlds[parsed_component.world_id];
    let name = &token_resource.token.name;
    let namespace = &token_resource.token.namespace;

    let import_function = if let Some(namespace) = namespace {
        let (_package_name, _interface_name, interface_id) = parsed_component
            .resolve
            .package_names
            .iter()
            .flat_map(|(package_name, package_id)| {
                let package = parsed_component.resolve.packages.get(*package_id).unwrap();
                package
                    .interfaces
                    .iter()
                    .map(|(interface_name, interface_id)| {
                        (package_name.clone(), interface_name.clone(), *interface_id)
                    })
            })
            .find(|(package_name, interface_name, _interface_id)| {
                let namespace = namespace.to_string();
                let full_name = package_name.interface_id(interface_name);
                full_name == namespace
            })
            .ok_or_else(|| {
                Error::Term(Box::new(format!("Could not find package name {namespace}")))
            })?;
        let interface = parsed_component
            .resolve
            .interfaces
            .get(interface_id)
            .unwrap();
        let (_function_name, function) = interface
            .functions
            .iter()
            .find(|(function_name, _function)| function_name.as_str() == name)
            .ok_or_else(|| {
                Error::Term(Box::new(format!("Could not find import function {name}")))
            })?;
        function
    } else {
        world
            .imports
            .iter()
            .filter_map(|(_, item)| match item {
                WorldItem::Function(function) => Some(function),
                _ => None,
            })
            .find(|f| f.item_name() == name)
            .ok_or_else(|| {
                Error::Term(Box::new(format!("Could not find import function {name}")))
            })?
    };

    let return_values = token_resource
        .token
        .return_values
        .lock()
        .map_err(|e| Error::Term(Box::new(format!("Failed to lock return values: {e}"))))?;

    convert_return_values(
        &component_resource.parsed.resolve,
        import_function,
        return_values,
        result,
    )
    .map_err(|e| {
        Error::Term(Box::new(format!(
            "Failed to convert imported function return values - {e}"
        )))
    })?;

    token_resource.token.continue_signal.notify_one();

    Ok(atoms::ok())
}

fn convert_return_values(
    wit_resolver: &Resolve,
    function: &Function,
    mut return_values: std::sync::MutexGuard<'_, Option<(bool, Vec<Val>)>>,
    result: Term,
) -> Result<(), String> {
    if let Some(result_type) = &function.result {
        let mut vals = Vec::new();
        vals.push(
            convert_result_term(result, result_type, wit_resolver, vec![]).map_err(
                |(msg, path)| {
                    if path.is_empty() {
                        msg
                    } else {
                        format!("{msg:?} at path: {path:?}")
                    }
                },
            )?,
        );

        // Set the return values
        *return_values = Some((true, vals));
    } else {
        *return_values = Some((true, vec![]));
    }

    Ok(())
}
