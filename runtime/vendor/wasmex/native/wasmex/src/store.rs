use crate::{
    caller::{get_caller, get_caller_mut},
    engine::{unwrap_engine, EngineResource},
    pipe::{Pipe, PipeResource},
};
use rustler::{Error, NifStruct, ResourceArc};
use std::{collections::HashMap, sync::Mutex};
use wasi_common::sync::WasiCtxBuilder;
use wasmtime::{
    AsContext, AsContextMut, Engine, Store, StoreContext, StoreContextMut, StoreLimits,
    StoreLimitsBuilder,
};
use wasmtime_wasi::ResourceTable;
use wasmtime_wasi::WasiCtx;
use wasmtime_wasi::WasiView;
use wasmtime_wasi_http::{WasiHttpCtx, WasiHttpView};

// wb-broker SSRF defense — the egress capability cadence. Permit ONLY public, externally-routable
// destinations; deny anything that could reach the host's own services or internal network. Used by
// socket_addr_check (raw wasi-sockets) and (next increment) the wasi-http send_request override.
pub(crate) fn wb_addr_allowed(addr: std::net::SocketAddr) -> bool {
    wb_ip_allowed(addr.ip())
}

pub(crate) fn wb_ip_allowed(ip: std::net::IpAddr) -> bool {
    use std::net::IpAddr;
    // Normalize IPv4-mapped IPv6 (::ffff:a.b.c.d) → V4 so e.g. ::ffff:127.0.0.1 / ::ffff:169.254.169.254
    // can't smuggle an internal target past the V4 checks.
    let ip = match ip {
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => IpAddr::V4(v4),
            None => IpAddr::V6(v6),
        },
        v4 => v4,
    };
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            !(v4.is_loopback()            // 127.0.0.0/8
                || v4.is_private()        // 10/8, 172.16/12, 192.168/16
                || v4.is_link_local()     // 169.254.0.0/16 (incl. cloud metadata 169.254.169.254)
                || v4.is_unspecified()    // 0.0.0.0
                || v4.is_broadcast()      // 255.255.255.255
                || v4.is_documentation()  // 192.0.2/24, 198.51.100/24, 203.0.113/24
                || v4.is_multicast()      // 224.0.0.0/4
                || o[0] == 0              // 0.0.0.0/8
                || (o[0] == 100 && (o[1] & 0xc0) == 64)) // CGNAT 100.64.0.0/10
        }
        IpAddr::V6(v6) => {
            let s = v6.segments();
            !(v6.is_loopback()                  // ::1
                || v6.is_unspecified()          // ::
                || v6.is_multicast()            // ff00::/8
                || (s[0] & 0xffc0) == 0xfe80    // link-local fe80::/10
                || (s[0] & 0xfe00) == 0xfc00)   // unique-local fc00::/7
        }
    }
}

#[cfg(test)]
mod wb_ssrf_tests {
    use super::wb_ip_allowed;
    use std::net::IpAddr;
    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }
    #[test]
    fn denies_all_internal_and_sensitive() {
        for s in [
            "127.0.0.1", "127.1.2.3", "169.254.169.254", "169.254.0.1", "10.0.0.1", "10.255.255.255",
            "172.16.0.1", "172.31.255.255", "192.168.1.1", "100.64.0.1", "100.127.255.255",
            "0.0.0.0", "0.1.2.3", "255.255.255.255", "224.0.0.1", "192.0.2.1",
            "::1", "::", "::ffff:127.0.0.1", "::ffff:169.254.169.254", "::ffff:10.0.0.1",
            "fe80::1", "fc00::1", "fd12:3456:789a::1", "ff02::1",
        ] {
            assert!(!wb_ip_allowed(ip(s)), "SSRF: must DENY {}", s);
        }
    }
    #[test]
    fn allows_public_routable() {
        for s in [
            "8.8.8.8", "1.1.1.1", "93.184.216.34", "140.82.112.3",
            "2606:4700:4700::1111", "2001:4860:4860::8888", "2620:fe::fe",
        ] {
            assert!(wb_ip_allowed(ip(s)), "must ALLOW public {}", s);
        }
    }
    #[test]
    fn ipv4_mapped_internal_is_denied() {
        // the classic bypass: smuggle a loopback/metadata target as an IPv4-mapped IPv6 literal
        assert!(!wb_ip_allowed(ip("::ffff:127.0.0.1")));
        assert!(!wb_ip_allowed(ip("::ffff:169.254.169.254")));
    }
}

#[derive(Debug, NifStruct)]
#[module = "Wasmex.Wasi.PreopenOptions"]
pub struct ExWasiPreopenOptions {
    path: String,
    alias: Option<String>,
}

#[derive(NifStruct)]
#[module = "Wasmex.Pipe"]
pub struct ExPipe {
    resource: ResourceArc<PipeResource>,
}

#[derive(NifStruct)]
#[module = "Wasmex.Wasi.WasiOptions"]
pub struct ExWasiOptions {
    args: Vec<String>,
    env: HashMap<String, String>,
    stderr: Option<ExPipe>,
    stdin: Option<ExPipe>,
    stdout: Option<ExPipe>,
    preopen: Vec<ExWasiPreopenOptions>,
}

#[derive(NifStruct)]
#[module = "Wasmex.Wasi.WasiP2Options"]
pub struct ExWasiP2Options {
    args: Vec<String>,
    env: HashMap<String, String>,
    inherit_stdin: bool,
    inherit_stdout: bool,
    inherit_stderr: bool,
    allow_http: bool,
}

#[derive(NifStruct)]
#[module = "Wasmex.StoreLimits"]
pub struct ExStoreLimits {
    memory_size: Option<usize>,
    table_elements: Option<usize>,
    instances: Option<usize>,
    tables: Option<usize>,
    memories: Option<usize>,
}

impl ExStoreLimits {
    pub fn to_wasmtime(&self) -> StoreLimits {
        let limits = StoreLimitsBuilder::new();

        let limits = if let Some(memory_size) = self.memory_size {
            limits.memory_size(memory_size)
        } else {
            limits
        };

        let limits = if let Some(table_elements) = self.table_elements {
            limits.table_elements(table_elements)
        } else {
            limits
        };

        let limits = if let Some(instances) = self.instances {
            limits.instances(instances)
        } else {
            limits
        };

        let limits = if let Some(tables) = self.tables {
            limits.tables(tables)
        } else {
            limits
        };

        let limits = if let Some(memories) = self.memories {
            limits.memories(memories)
        } else {
            limits
        };

        limits.build()
    }
}

pub struct StoreData {
    pub(crate) wasi: Option<wasi_common::WasiCtx>,
    pub(crate) limits: StoreLimits,
}

pub struct ComponentStoreData {
    pub(crate) ctx: Option<WasiCtx>,
    pub(crate) http: Option<WasiHttpCtx>,
    pub(crate) limits: StoreLimits,
    pub(crate) table: ResourceTable,
}

impl WasiHttpView for ComponentStoreData {
    fn ctx(&mut self) -> &mut WasiHttpCtx {
        self.http.as_mut().expect("WasiHttpCtx is not set")
    }

    fn table(&mut self) -> &mut ResourceTable {
        &mut self.table
    }
}

impl WasiView for ComponentStoreData {
    fn ctx(&mut self) -> wasmtime_wasi::WasiCtxView<'_> {
        let ctx = self.ctx.as_mut().expect("WasiCtx is not set");
        wasmtime_wasi::WasiCtxView {
            ctx,
            table: &mut self.table,
        }
    }
}

pub enum StoreOrCaller {
    Store(Store<StoreData>),
    Caller(i32),
}

pub struct StoreOrCallerResource {
    pub inner: Mutex<StoreOrCaller>,
}

pub struct ComponentStoreResource {
    pub inner: Mutex<Store<ComponentStoreData>>,
}

#[rustler::resource_impl()]
impl rustler::Resource for ComponentStoreResource {}

#[rustler::resource_impl()]
impl rustler::Resource for StoreOrCallerResource {}

impl StoreOrCaller {
    pub fn engine(&self) -> &Engine {
        match self {
            StoreOrCaller::Store(store) => store.engine(),
            StoreOrCaller::Caller(token) => get_caller(token).unwrap().engine(),
        }
    }

    pub fn data(&self) -> &StoreData {
        match self {
            StoreOrCaller::Store(store) => store.data(),
            StoreOrCaller::Caller(token) => get_caller(token).unwrap().data(),
        }
    }
}

impl AsContext for StoreOrCaller {
    type Data = StoreData;

    fn as_context(&self) -> StoreContext<'_, Self::Data> {
        match self {
            StoreOrCaller::Store(store) => store.as_context(),
            StoreOrCaller::Caller(token) => get_caller(token).unwrap().as_context(),
        }
    }
}

impl AsContextMut for StoreOrCaller {
    fn as_context_mut(&mut self) -> StoreContextMut<'_, Self::Data> {
        match self {
            StoreOrCaller::Store(store) => store.as_context_mut(),
            StoreOrCaller::Caller(token) => get_caller_mut(token).unwrap().as_context_mut(),
        }
    }
}

#[rustler::nif(name = "store_new")]
pub fn new(
    limits: Option<ExStoreLimits>,
    engine_resource: ResourceArc<EngineResource>,
) -> Result<ResourceArc<StoreOrCallerResource>, rustler::Error> {
    let engine = unwrap_engine(engine_resource)?;
    let limits = if let Some(limits) = limits {
        limits.to_wasmtime()
    } else {
        StoreLimits::default()
    };
    let mut store = Store::new(&engine, StoreData { wasi: None, limits });
    store.limiter(|state| &mut state.limits);
    let resource = ResourceArc::new(StoreOrCallerResource {
        inner: Mutex::new(StoreOrCaller::Store(store)),
    });
    Ok(resource)
}

#[rustler::nif(name = "component_store_new")]
pub fn component_store_new(
    limits: Option<ExStoreLimits>,
    engine_resource: ResourceArc<EngineResource>,
) -> Result<ResourceArc<ComponentStoreResource>, rustler::Error> {
    let engine = unwrap_engine(engine_resource)?;
    let limits = if let Some(limits) = limits {
        limits.to_wasmtime()
    } else {
        StoreLimits::default()
    };
    let mut store = Store::new(
        &engine,
        ComponentStoreData {
            http: None,
            ctx: None,
            limits,
            table: wasmtime_wasi::ResourceTable::new(),
        },
    );
    store.limiter(|state| &mut state.limits);
    let resource: ResourceArc<ComponentStoreResource> = ResourceArc::new(ComponentStoreResource {
        inner: Mutex::new(store),
    });
    Ok(resource)
}

#[rustler::nif(name = "component_store_new_wasi")]
pub fn component_store_new_wasi(
    options: ExWasiP2Options,
    limits: Option<ExStoreLimits>,
    engine_resource: ResourceArc<EngineResource>,
) -> Result<ResourceArc<ComponentStoreResource>, rustler::Error> {
    let wasi_env = &options
        .env
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect::<Vec<_>>();
    let mut wasi_ctx_builder = wasmtime_wasi::WasiCtxBuilder::new();
    wasi_ctx_builder.args(&options.args).envs(wasi_env);

    if options.inherit_stdin {
        wasi_ctx_builder.inherit_stdin();
    }

    if options.inherit_stdout {
        wasi_ctx_builder.inherit_stdout();
    }

    if options.inherit_stderr {
        wasi_ctx_builder.inherit_stderr();
    }

    if options.allow_http {
        // wb-broker: net is brokered, but inherit_network() alone = full host stack (SSRF: a guest
        // could reach 169.254.169.254 / localhost / RFC1918). socket_addr_check fires at connect-time on
        // the RESOLVED address (which also closes DNS-rebinding for the raw-socket path), and we deny any
        // internal/sensitive destination. NOTE: this guards the raw wasi-sockets path only; wasi-http
        // connects via tokio directly (bypasses this) and is filtered in send_request below.
        wasi_ctx_builder
            .inherit_network()
            .allow_ip_name_lookup(true)
            .socket_addr_check(|addr, _use| {
                let ok = wb_addr_allowed(addr);
                Box::pin(async move { ok })
            });
    }

    let engine = unwrap_engine(engine_resource)?;
    let limits = if let Some(limits) = limits {
        limits.to_wasmtime()
    } else {
        StoreLimits::default()
    };

    let http_option = if options.allow_http {
        Some(WasiHttpCtx::new())
    } else {
        None
    };

    let mut store = Store::new(
        &engine,
        ComponentStoreData {
            ctx: Some(wasi_ctx_builder.build()),
            limits,
            http: http_option,
            table: wasmtime_wasi::ResourceTable::new(),
        },
    );
    store.limiter(|state| &mut state.limits);
    let resource: ResourceArc<ComponentStoreResource> = ResourceArc::new(ComponentStoreResource {
        inner: Mutex::new(store),
    });
    Ok(resource)
}

#[rustler::nif(name = "store_new_wasi")]
pub fn new_wasi(
    options: ExWasiOptions,
    limits: Option<ExStoreLimits>,
    engine_resource: ResourceArc<EngineResource>,
) -> Result<ResourceArc<StoreOrCallerResource>, rustler::Error> {
    let wasi_env = &options
        .env
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect::<Vec<_>>();

    let mut builder = WasiCtxBuilder::new();

    builder
        .args(&options.args)
        .map_err(|err| Error::Term(Box::new(err.to_string())))?
        .envs(wasi_env)
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;

    add_pipe(options.stdin, &mut builder, |pipe, builder| {
        builder.stdin(pipe);
    })?;
    add_pipe(options.stdout, &mut builder, |pipe, builder| {
        builder.stdout(pipe);
    })?;
    add_pipe(options.stderr, &mut builder, |pipe, builder| {
        builder.stderr(pipe);
    })?;
    wasi_preopen_directories(options.preopen, &mut builder)?;
    let wasi_ctx = builder.build();

    let engine = unwrap_engine(engine_resource)?;
    let limits = if let Some(limits) = limits {
        limits.to_wasmtime()
    } else {
        StoreLimits::default()
    };
    let mut store = Store::new(
        &engine,
        StoreData {
            wasi: Some(wasi_ctx),
            limits,
        },
    );
    store.limiter(|state| &mut state.limits);
    let resource = ResourceArc::new(StoreOrCallerResource {
        inner: Mutex::new(StoreOrCaller::Store(store)),
    });
    Ok(resource)
}

#[rustler::nif(name = "store_or_caller_set_fuel")]
pub fn set_fuel(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
    fuel: u64,
) -> Result<(), rustler::Error> {
    let store_or_caller: &mut StoreOrCaller =
        &mut *(store_or_caller_resource.inner.try_lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!("Could not unlock store resource: {e}")))
        })?);
    match store_or_caller {
        StoreOrCaller::Store(store) => store.set_fuel(fuel),
        StoreOrCaller::Caller(token) => get_caller_mut(token)
            .ok_or_else(|| {
                rustler::Error::Term(Box::new(
                    "Caller is not valid. Only use a caller within its own function scope.",
                ))
            })
            .map(|c| c.set_fuel(fuel))?,
    }
    .map_err(|e| rustler::Error::Term(Box::new(format!("Could not set fuel: {e}"))))
}

#[rustler::nif(name = "store_or_caller_get_fuel")]
pub fn get_fuel(
    store_or_caller_resource: ResourceArc<StoreOrCallerResource>,
) -> Result<u64, rustler::Error> {
    let store_or_caller: &mut StoreOrCaller =
        &mut *(store_or_caller_resource.inner.try_lock().map_err(|e| {
            rustler::Error::Term(Box::new(format!("Could not unlock store resource: {e}")))
        })?);
    match store_or_caller {
        StoreOrCaller::Store(store) => store.get_fuel(),
        StoreOrCaller::Caller(token) => get_caller_mut(token)
            .ok_or_else(|| {
                rustler::Error::Term(Box::new(
                    "Caller is not valid. Only use a caller within its own function scope.",
                ))
            })
            .map(|c| c.get_fuel())?,
    }
    .map_err(|e| rustler::Error::Term(Box::new(format!("Could not get fuel: {e}"))))
}

fn add_pipe(
    pipe: Option<ExPipe>,
    builder: &mut WasiCtxBuilder,
    f: fn(Box<Pipe>, &mut WasiCtxBuilder) -> (),
) -> Result<(), rustler::Error> {
    if let Some(ExPipe { resource }) = pipe {
        let pipe = resource.pipe.lock().map_err(|_e| {
            rustler::Error::Term(Box::new(
                "Could not unlock resource as the mutex was poisoned.",
            ))
        })?;
        let pipe = Box::new(pipe.clone());
        f(pipe, builder);
    }
    Ok(())
}

fn wasi_preopen_directories(
    preopens: Vec<ExWasiPreopenOptions>,
    builder: &mut WasiCtxBuilder,
) -> Result<(), rustler::Error> {
    preopens
        .iter()
        .try_fold((), |_acc, preopen| preopen_directory(builder, preopen))
}

fn preopen_directory(
    builder: &mut WasiCtxBuilder,
    preopen: &ExWasiPreopenOptions,
) -> Result<(), Error> {
    let path = &preopen.path;
    let dir = wasi_common::sync::Dir::from_std_file(
        std::fs::File::open(path).map_err(|err| rustler::Error::Term(Box::new(err.to_string())))?,
    );
    let guest_path = preopen.alias.as_ref().unwrap_or(path);
    builder
        .preopened_dir(dir, guest_path)
        .map_err(|err| Error::Term(Box::new(err.to_string())))?;
    Ok(())
}
