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
use wasmtime_wasi_http::{HttpError, HttpResult, WasiHttpCtx, WasiHttpView};
use wasmtime_wasi_http::bindings::http::types::ErrorCode;
use wasmtime_wasi_http::body::HyperOutgoingBody;
use wasmtime_wasi_http::types::{
    default_send_request, HostFutureIncomingResponse, OutgoingRequestConfig,
};

// wb-broker SSRF defense — the egress capability cadence. Permit ONLY public, externally-routable
// destinations; deny anything that could reach the host's own services or internal network. Used by
// socket_addr_check (raw wasi-sockets) and (next increment) the wasi-http send_request override.
// Per-instance IP scope for the raw-socket path. `net_allow` None/empty = no scoping (any public, after the
// SSRF floor). With entries, the connecting IP must match an IP entry ("1.1.1.1" or "1.1.1.1:port" or an
// IPv6 literal). Hostname entries (for wasi-http) don't match an IP, so a hostname-only scope denies raw
// sockets entirely — a sane least-privilege default.
pub(crate) fn wb_addr_in_scope(addr: std::net::SocketAddr, net_allow: &Option<Vec<String>>) -> bool {
    match net_allow {
        Some(list) if !list.is_empty() => {
            let ip = addr.ip().to_string();
            list.iter().any(|e| {
                if e == &ip {
                    return true;
                }
                match e.rsplit_once(':') {
                    Some((h, p)) if p.parse::<u16>().is_ok() => h == ip,
                    _ => false,
                }
            })
        }
        _ => true,
    }
}

// Resolve `host` ONCE and return a single allowed (public) IP to PIN the wasi-http connection to — closing
// the DNS-rebinding window (the host re-resolving between our check and the actual connect). None if it
// doesn't resolve or ANY resolved address is internal/non-routable.
pub(crate) fn wb_resolve_pinned(host: &str, port: u16) -> Option<std::net::IpAddr> {
    use std::net::ToSocketAddrs;
    match (host, port).to_socket_addrs() {
        Ok(addrs) => {
            let addrs: Vec<_> = addrs.collect();
            if !addrs.is_empty() && addrs.iter().all(|a| wb_ip_allowed(a.ip())) {
                Some(addrs[0].ip())
            } else {
                None
            }
        }
        Err(_) => None,
    }
}

pub(crate) fn wb_addr_allowed(addr: std::net::SocketAddr) -> bool {
    wb_ip_allowed(addr.ip())
}

// DNS-EXFIL defense: name lookup is needed only when the guest must resolve a HOSTNAME. If net_allow is set
// and every entry is an IP literal (an IP-scoped guest), the guest never needs DNS — so we disable name
// lookup entirely, closing DNS-exfil (a malicious guest can't leak data by resolving attacker subdomains).
// Unscoped or hostname-scoped guests keep DNS (they need to resolve names to fetch).
pub(crate) fn wb_dns_needed(net_allow: &Option<Vec<String>>) -> bool {
    match net_allow {
        Some(list) if !list.is_empty() => list.iter().any(|e| {
            let host = match e.rsplit_once(':') {
                Some((h, p)) if p.parse::<u16>().is_ok() => h,
                _ => e.as_str(),
            };
            // a hostname (not parseable as an IP) means DNS is required
            host.parse::<std::net::IpAddr>().is_err()
        }),
        _ => true,
    }
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

/// Resolve a request authority and permit it ONLY if EVERY resolved address is public/routable.
/// Deny on resolution failure or empty result. Used by the wasi-http send_request override (the
/// complement to socket_addr_check, since wasi-http connects via tokio directly). Closes IP-literal
/// and static-DNS SSRF for HTTP; an active-DNS-rebinding window for hostnames remains until we pin the
/// resolved IP into the connector (next refinement) — the raw-socket path already pins via the SocketAddr.
pub(crate) fn wb_host_allowed(host: &str, port: u16) -> bool {
    use std::net::ToSocketAddrs;
    match (host, port).to_socket_addrs() {
        Ok(addrs) => {
            let mut any = false;
            for a in addrs {
                any = true;
                if !wb_ip_allowed(a.ip()) {
                    return false;
                }
            }
            any
        }
        Err(_) => false,
    }
}

/// Per-instance egress allow-list match for the wasi-http path (where we have the hostname).
/// Entry forms (case-insensitive): "host" (any port), "host:port" (exact port), "*.suffix" (host or any
/// subdomain), "*.suffix:port". This SCOPES egress on top of the always-on SSRF deny-internal floor;
/// an empty/None list (caller's choice) means "no extra scoping" (allow any public dest after SSRF).
pub(crate) fn wb_host_in_allowlist(host: &str, port: u16, allow: &[String]) -> bool {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    allow.iter().any(|raw| {
        let e = raw.trim().to_ascii_lowercase();
        let (pat, eport): (&str, Option<u16>) = match e.rsplit_once(':') {
            Some((h, p)) => match p.parse::<u16>() {
                Ok(pn) => (h, Some(pn)),
                Err(_) => (e.as_str(), None),
            },
            None => (e.as_str(), None),
        };
        if let Some(ep) = eport {
            if ep != port {
                return false;
            }
        }
        match pat.strip_prefix("*.") {
            Some(suffix) => host == suffix || host.ends_with(&format!(".{}", suffix)),
            None => host == pat,
        }
    })
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

    // wb_host_allowed: the wasi-http override's resolve-then-check path. Hermetic — IP literals need no
    // DNS; "localhost" resolves via /etc/hosts to loopback on every system.
    #[test]
    fn host_allowed_denies_internal_and_localhost() {
        use super::wb_host_allowed;
        assert!(!wb_host_allowed("127.0.0.1", 80), "deny loopback literal");
        assert!(!wb_host_allowed("169.254.169.254", 80), "deny cloud metadata");
        assert!(!wb_host_allowed("10.0.0.1", 443), "deny RFC1918");
        assert!(!wb_host_allowed("::1", 80), "deny IPv6 loopback literal (brackets stripped upstream)");
        assert!(!wb_host_allowed("localhost", 80), "deny localhost (resolves to loopback)");
    }
    #[test]
    fn host_allowed_permits_public_literal() {
        use super::wb_host_allowed;
        assert!(wb_host_allowed("8.8.8.8", 80), "allow public literal");
        assert!(wb_host_allowed("1.1.1.1", 443), "allow public literal");
    }

    #[test]
    fn addr_in_scope_ip_allowlist() {
        use super::wb_addr_in_scope as s;
        use std::net::{IpAddr, Ipv4Addr, SocketAddr};
        let a = |o: [u8; 4], port: u16| SocketAddr::new(IpAddr::V4(Ipv4Addr::new(o[0], o[1], o[2], o[3])), port);

        // no scope (None/empty) -> allow any (after the SSRF floor)
        assert!(s(a([8, 8, 8, 8], 80), &None));
        assert!(s(a([8, 8, 8, 8], 80), &Some(vec![])));
        // exact IP entry matches; entry with :port matches
        assert!(s(a([1, 1, 1, 1], 80), &Some(vec!["1.1.1.1".into()])));
        assert!(s(a([1, 1, 1, 1], 443), &Some(vec!["1.1.1.1:443".into()])));
        // a different public IP is NOT in the scope -> denied
        assert!(!s(a([8, 8, 8, 8], 80), &Some(vec!["1.1.1.1".into()])));
        // hostname-only scope has no IP match -> raw sockets denied (least-privilege default)
        assert!(!s(a([1, 1, 1, 1], 80), &Some(vec!["example.com".into()])));
    }

    #[test]
    fn dns_needed_only_for_hostname_scopes() {
        use super::wb_dns_needed as d;
        assert!(d(&None), "unscoped -> DNS on");
        assert!(d(&Some(vec![])), "empty scope -> DNS on");
        // IP-only scope -> no DNS (DNS-exfil closed)
        assert!(!d(&Some(vec!["1.1.1.1".into()])));
        assert!(!d(&Some(vec!["1.1.1.1".into(), "8.8.8.8:443".into()])));
        // a hostname entry -> DNS needed
        assert!(d(&Some(vec!["example.com".into()])));
        assert!(d(&Some(vec!["1.1.1.1".into(), "example.com".into()])), "mixed -> DNS on");
    }

    #[test]
    fn egress_rate_quota_meters_the_wasi_http_path() {
        use std::time::{Duration, Instant};
        let mut sd = super::ComponentStoreData {
            ctx: None,
            http: None,
            limits: wasmtime::StoreLimits::default(),
            table: wasmtime_wasi::ResourceTable::new(),
            net_allow: None,
            egress_count: 0,
            egress_window: None,
        };
        let t0 = Instant::now();
        let win = Duration::from_secs(10);
        // max = 2 within the window: first two pass, the third is over quota
        assert!(sd.egress_allowed(t0, win, 2));
        assert!(sd.egress_allowed(t0, win, 2));
        assert!(!sd.egress_allowed(t0, win, 2), "3rd request in-window exceeds the quota");
        // a fresh window resets the count
        let t1 = t0 + Duration::from_secs(11);
        assert!(sd.egress_allowed(t1, win, 2), "new window resets");
        assert!(sd.egress_allowed(t1, win, 2));
        assert!(!sd.egress_allowed(t1, win, 2));
    }

    #[test]
    fn allowlist_matching() {
        use super::wb_host_in_allowlist as m;
        let allow = vec![
            "example.com".to_string(),
            "*.api.github.com".to_string(),
            "secure.test:443".to_string(),
        ];
        // matches
        assert!(m("example.com", 80, &allow), "exact host any port");
        assert!(m("EXAMPLE.COM", 443, &allow), "case-insensitive");
        assert!(m("example.com.", 80, &allow), "trailing-dot FQDN normalized");
        assert!(m("v3.api.github.com", 443, &allow), "wildcard subdomain");
        assert!(m("api.github.com", 80, &allow), "wildcard base matches");
        assert!(m("secure.test", 443, &allow), "exact host + port");
        // non-matches
        assert!(!m("secure.test", 80, &allow), "wrong port denied");
        assert!(!m("evil.com", 80, &allow), "unlisted host denied");
        assert!(!m("notexample.com", 80, &allow), "suffix-confusion denied");
        assert!(!m("github.com", 80, &allow), "*.api.github.com != github.com");
        assert!(!m("x.example.com", 80, &allow), "exact entry != subdomain");
        assert!(!m("anything.com", 80, &[]), "empty list matches nothing");
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
    // wb-broker: optional per-instance egress allow-list (host / host:port / *.suffix). None or empty =
    // no extra scoping (any public dest, after the SSRF deny-internal floor). Decodes from the Elixir
    // WasiP2Options :net_allow field (nil -> None).
    net_allow: Option<Vec<String>>,
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
    // wb-broker: per-instance egress allow-list, read by the WasiHttpView::send_request SSRF/scope check.
    pub(crate) net_allow: Option<Vec<String>>,
    // wb-broker: per-instance egress RATE meter (the wasi-http path was otherwise UNMETERED) — counts
    // outbound requests in a sliding window so a runaway/red-team standard tool can't flood (rate/conn DoS).
    pub(crate) egress_count: u32,
    pub(crate) egress_window: Option<std::time::Instant>,
}

impl ComponentStoreData {
    // Sliding-window egress meter: counts this outbound request and returns whether it's within `max` per
    // `window`. A fresh window resets the count. (`now` is injected so the logic is unit-testable.)
    pub(crate) fn egress_allowed(
        &mut self,
        now: std::time::Instant,
        window: std::time::Duration,
        max: u32,
    ) -> bool {
        match self.egress_window {
            Some(start) if now.duration_since(start) < window => {
                self.egress_count += 1;
                self.egress_count <= max
            }
            _ => {
                self.egress_window = Some(now);
                self.egress_count = 1;
                true
            }
        }
    }
}

impl WasiHttpView for ComponentStoreData {
    fn ctx(&mut self) -> &mut WasiHttpCtx {
        self.http.as_mut().expect("WasiHttpCtx is not set")
    }

    fn table(&mut self) -> &mut ResourceTable {
        &mut self.table
    }

    // wb-broker SSRF: wasi-http connects via tokio directly (bypassing socket_addr_check), so the egress
    // policy MUST be enforced here too. Resolve the request authority and deny if any resolved IP is
    // internal/sensitive (loopback/metadata/RFC1918/etc — see wb_ip_allowed). Denied requests fail at the
    // boundary; allowed ones fall through to the default handler.
    fn send_request(
        &mut self,
        request: hyper::Request<HyperOutgoingBody>,
        config: OutgoingRequestConfig,
    ) -> HttpResult<HostFutureIncomingResponse> {
        // per-instance egress RATE quota (the wasi-http path was otherwise unmetered): bound a runaway /
        // red-team standard tool — caps both sustained floods and concurrent-burst amplification (every
        // in-flight request counts) to 50k outbound requests / 10s per instance.
        if !self.egress_allowed(
            std::time::Instant::now(),
            std::time::Duration::from_secs(10),
            50_000,
        ) {
            return Err(HttpError::from(ErrorCode::InternalError(Some(
                "wb-broker: egress rate quota exceeded".to_string(),
            ))));
        }

        let uri = request.uri();
        let host = match uri.host() {
            Some(h) => h.trim_start_matches('[').trim_end_matches(']').to_string(),
            None => {
                return Err(HttpError::from(ErrorCode::InternalError(Some(
                    "wb-broker: outgoing request has no host".to_string(),
                ))));
            }
        };
        let is_https = uri.scheme_str() == Some("https");
        let port = uri.port_u16().unwrap_or(if is_https { 443 } else { 80 });

        // Resolve ONCE + SSRF floor: deny if unresolvable or any resolved IP is internal; keep the pinned IP.
        let pinned = match wb_resolve_pinned(&host, port) {
            Some(ip) => ip,
            None => {
                return Err(HttpError::from(ErrorCode::InternalError(Some(
                    "wb-broker: destination denied by egress policy (internal/non-routable address)"
                        .to_string(),
                ))))
            }
        };
        // Scoped allow-list (on top of the SSRF floor): if this instance was granted a non-empty list,
        // the destination host must match it. No list (None/empty) = no extra scoping.
        if let Some(list) = &self.net_allow {
            if !list.is_empty() && !wb_host_in_allowlist(&host, port, list) {
                return Err(HttpError::from(ErrorCode::InternalError(Some(
                    "wb-broker: destination not in the instance egress allow-list".to_string(),
                ))));
            }
        }

        // DNS-REBINDING PIN: connect to the IP we just checked, not the hostname (which default_send_request
        // would RE-resolve, leaving a rebind window). For http, rewrite the authority to the pinned IP and
        // keep the original Host header for vhost routing. For https we leave the SNI hostname intact —
        // TLS cert validation already binds the connection to the hostname, so a rebind to an internal IP
        // fails the handshake (it can't present the hostname's cert).
        let mut request = request;
        if !is_https {
            if let Ok(hv) = hyper::header::HeaderValue::from_str(&host) {
                request.headers_mut().insert(hyper::header::HOST, hv);
            }
            let auth_str = match pinned {
                std::net::IpAddr::V6(v6) => format!("[{}]:{}", v6, port),
                v4 => format!("{}:{}", v4, port),
            };
            if let Ok(authority) = auth_str.parse::<hyper::http::uri::Authority>() {
                let mut parts = request.uri().clone().into_parts();
                parts.authority = Some(authority);
                if let Ok(new_uri) = hyper::Uri::from_parts(parts) {
                    *request.uri_mut() = new_uri;
                }
            }
        }
        Ok(default_send_request(request, config))
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
            net_allow: None,
            egress_count: 0,
            egress_window: None,
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
        // Per-instance IP scoping for the raw-socket path: if net_allow has IP entries, the connecting IP
        // must match one (default-deny scope on top of the SSRF floor). Hostname entries don't apply here
        // (the socket layer has only the resolved IP, no hostname) — those scope the wasi-http path instead.
        let net_allow_for_sockets = options.net_allow.clone();
        wasi_ctx_builder
            .inherit_network()
            // DNS-exfil: an IP-only-scoped guest gets NO name lookup (it can't leak via DNS queries).
            .allow_ip_name_lookup(wb_dns_needed(&options.net_allow))
            .socket_addr_check(move |addr, _use| {
                let ok = wb_addr_allowed(addr) && wb_addr_in_scope(addr, &net_allow_for_sockets);
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
            net_allow: options.net_allow.clone(),
            egress_count: 0,
            egress_window: None,
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
