import type {} from './porffor.d.ts';

// JS Proxy builtin.
//
// Representation: a Proxy is allocated as a normal object pointer whose RUNTIME type is
// TYPES.object (so codegen keeps routing member access through the object builtins), but the
// object's flags byte (offset 2) has bit 1 (value 2) set to mark it a proxy. Its header size is
// kept at 0 so no entry-walk ever touches the raw slots where we stash target + handler.
//
// raw layout (proxy):
//   [size:u16 @0 = 0][flags:u8 @2 = proxy bit][protoType:u8 @3][proto:i32 @4]
//   [target:f64 @8][handler:f64 @16][targetType:u8 @24][handlerType:u8 @25]

export const __Porffor_proxy_target = (obj: any): any => {
  const ptr: i32 = Porffor.wasm`local.get ${obj}`;
  const val: f64 = Porffor.wasm.f64.load(ptr, 0, 8);
  const ty: i32 = Porffor.wasm.i32.load8_u(ptr, 0, 24);
  Porffor.wasm`
local.get ${val}
local.get ${ty}
return`;
};

export const __Porffor_proxy_handler = (obj: any): any => {
  const ptr: i32 = Porffor.wasm`local.get ${obj}`;
  const val: f64 = Porffor.wasm.f64.load(ptr, 0, 16);
  const ty: i32 = Porffor.wasm.i32.load8_u(ptr, 0, 25);
  Porffor.wasm`
local.get ${val}
local.get ${ty}
return`;
};

// Read a trap off the handler object. Returns the trap (a function or a boxed closure) or
// undefined if absent. The handler is a real object so a plain object_get is safe here (the
// handler itself is NOT a proxy).
export const __Porffor_proxy_trap = (handler: any, name: any): any => {
  const trap: any = handler[name];
  if (Porffor.type(trap) == Porffor.TYPES.undefined) return undefined;
  if (trap == null) return undefined;
  return trap;
};

// Call a trap (function or boxed closure {__clo,env,fn}) with up to 3 args. A funcref must be
// called from an ARRAY slot, never read straight off an object property.
export const __Porffor_proxy_call3 = (trap: any, a: any, b: any, c: any, argc: i32): any => {
  let boxed: i32 = 0;
  if (Porffor.type(trap) == Porffor.TYPES.object) { if (trap.__clo) boxed = 1; }

  if (boxed) {
    const slot: any[] = Porffor.malloc(16);
    slot[0] = trap.fn;
    const f: any = slot[0];
    if (trap.__method) {
      if (argc == 2) return f(trap.env, undefined, a, b);
      if (argc == 3) return f(trap.env, undefined, a, b, c);
      return f(trap.env, undefined, a);
    }
    if (argc == 2) return f(trap.env, a, b);
    if (argc == 3) return f(trap.env, a, b, c);
    return f(trap.env, a);
  }

  if (argc == 2) return trap.call(undefined, a, b);
  if (argc == 3) return trap.call(undefined, a, b, c);
  return trap.call(undefined, a);
};

// ---- revocation state ----
// Revoked = flags bit 0b0100 on the proxy object; the proxy bit (0b0010) stays set so member access
// keeps routing through the trap dispatchers, which check revoked first and throw TypeError.

export const __Porffor_proxy_isRevoked = (p: any): boolean => {
  if (Porffor.wasm`local.get ${p+1}` != Porffor.TYPES.object) return false;
  if (Porffor.wasm`local.get ${p}` == 0) return false;
  const flags: i32 = Porffor.wasm.i32.load8_u(p, 0, 2);
  if ((flags & 0b0010) == 0) return false;
  return (flags & 0b0100) as boolean;
};

export const __Porffor_proxy_revoke = (p: any): void => {
  if (Porffor.wasm`local.get ${p+1}` != Porffor.TYPES.object) return;
  const flags: i32 = Porffor.wasm.i32.load8_u(p, 0, 2);
  Porffor.wasm.i32.store8(p, flags | 0b0100, 0, 2);
};

export const __Porffor_proxy_revokedCheck = (p: any, op: any): void => {
  if (__Porffor_proxy_isRevoked(p)) throw new TypeError('Cannot perform operation on a revoked proxy');
};

export const Proxy = function (target: any, handler: any): object {
  if (!new.target) throw new TypeError("Constructor Proxy requires 'new'");
  if (!Porffor.object.isObject(target)) throw new TypeError('Cannot create proxy with a non-object as target');
  if (!Porffor.object.isObject(handler)) throw new TypeError('Cannot create proxy with a non-object as handler');
  // NOTE: current spec (post-ES2021 ProxyCreate) permits a REVOKED proxy as target or handler at
  // creation — only operations through it throw. Do not re-add revoked checks here.

  const out: object = Porffor.malloc(32);
  // header: size=0
  Porffor.wasm.i32.store16(out, 0, 0, 0);
  // flags byte: proxy bit (0b0010). no cap-class -> fastAdd guard skipped (we never fastAdd here).
  Porffor.wasm.i32.store8(out, 0b0010, 0, 2);
  // protoType=undefined(0), proto=0
  Porffor.wasm.i32.store8(out, 0, 0, 3);
  Porffor.wasm.i32.store(out, 0, 0, 4);

  // stash target + handler (value + type)
  Porffor.wasm.f64.store(out, target, 0, 8);
  Porffor.wasm.f64.store(out, handler, 0, 16);
  Porffor.wasm.i32.store8(out, Porffor.wasm`local.get ${target+1}`, 0, 24);
  Porffor.wasm.i32.store8(out, Porffor.wasm`local.get ${handler+1}`, 0, 25);

  return out;
};

// Proxy.revocable(target, handler) -> { proxy, revoke }. The precompile lane has no closure
// conversion (a builtin closure cannot capture `p`), so revoke reads the proxy off `this` — covering
// the method-style `r.revoke()` the suite uses. A destructured bare `revoke()` is a known limit.
export const __Porffor_proxy_revokeThis = function (): void {
  __Porffor_proxy_revoke(this.proxy);
};

export const __Proxy_revocable = (target: any, handler: any): object => {
  const p: any = new Proxy(target, handler);
  const out: object = {};
  out.proxy = p;
  out.revoke = __Porffor_proxy_revokeThis;
  return out;
};

// ---- trap dispatchers (called from the hooked object builtins) ----

export const __Porffor_proxy_get = (p: any, key: any): any => {
  __Porffor_proxy_revokedCheck(p, 'get');
  const target: any = __Porffor_proxy_target(p);
  const handler: any = __Porffor_proxy_handler(p);
  const trap: any = __Porffor_proxy_trap(handler, 'get');
  if (Porffor.type(trap) == Porffor.TYPES.undefined) return Reflect.get(target, key);
  return __Porffor_proxy_call3(trap, target, key, p, 3);
};

export const __Porffor_proxy_set = (p: any, key: any, value: any): any => {
  __Porffor_proxy_revokedCheck(p, 'set');
  const target: any = __Porffor_proxy_target(p);
  const handler: any = __Porffor_proxy_handler(p);
  const trap: any = __Porffor_proxy_trap(handler, 'set');
  if (Porffor.type(trap) == Porffor.TYPES.undefined) {
    Reflect.set(target, key, value);
    return value;
  }
  // set(target, key, value, receiver) — call with 3 meaningful args (receiver omitted, parity ok)
  __Porffor_proxy_call3(trap, target, key, value, 3);
  return value;
};

export const __Porffor_proxy_has = (p: any, key: any): boolean => {
  __Porffor_proxy_revokedCheck(p, 'has');
  const target: any = __Porffor_proxy_target(p);
  const handler: any = __Porffor_proxy_handler(p);
  const trap: any = __Porffor_proxy_trap(handler, 'has');
  if (Porffor.type(trap) == Porffor.TYPES.undefined) return Reflect.has(target, key);
  return !!__Porffor_proxy_call3(trap, target, key, undefined, 2);
};

export const __Porffor_proxy_deleteProperty = (p: any, key: any): boolean => {
  __Porffor_proxy_revokedCheck(p, 'deleteProperty');
  const target: any = __Porffor_proxy_target(p);
  const handler: any = __Porffor_proxy_handler(p);
  const trap: any = __Porffor_proxy_trap(handler, 'deleteProperty');
  if (Porffor.type(trap) == Porffor.TYPES.undefined) return Reflect.deleteProperty(target, key);
  return !!__Porffor_proxy_call3(trap, target, key, undefined, 2);
};

export const __Porffor_proxy_ownKeys = (p: any): any => {
  __Porffor_proxy_revokedCheck(p, 'ownKeys');
  const target: any = __Porffor_proxy_target(p);
  const handler: any = __Porffor_proxy_handler(p);
  const trap: any = __Porffor_proxy_trap(handler, 'ownKeys');
  if (Porffor.type(trap) == Porffor.TYPES.undefined) return Reflect.ownKeys(target);
  return __Porffor_proxy_call3(trap, target, undefined, undefined, 1);
};
