//! wasi-threads thread-local keys, backed directly by wasi-libc's pthread_key_*
//! (the `libc` crate's wasi module doesn't expose these, so we declare the externs
//! inline — same approach `sys/wasi/thread.rs` uses for pthread_create).
//! (Workbooks multithreaded-Rust patch.)
#![allow(non_camel_case_types)]

use crate::ffi::c_int;

pub type pthread_key_t = ::core::ffi::c_uint;
pub type Key = pthread_key_t;

extern "C" {
    fn pthread_key_create(
        key: *mut pthread_key_t,
        dtor: Option<unsafe extern "C" fn(*mut u8)>,
    ) -> c_int;
    fn pthread_key_delete(key: pthread_key_t) -> c_int;
    fn pthread_setspecific(key: pthread_key_t, value: *const u8) -> c_int;
    fn pthread_getspecific(key: pthread_key_t) -> *mut u8;
}

#[inline]
pub unsafe fn create(dtor: Option<unsafe extern "C" fn(*mut u8)>) -> Key {
    let mut key: pthread_key_t = 0;
    assert_eq!(pthread_key_create(&mut key, dtor), 0);
    key
}

#[inline]
pub unsafe fn set(key: Key, value: *mut u8) {
    let r = pthread_setspecific(key, value);
    debug_assert_eq!(r, 0);
}

#[inline]
pub unsafe fn get(key: Key) -> *mut u8 {
    pthread_getspecific(key)
}

#[inline]
pub unsafe fn destroy(key: Key) {
    let r = pthread_key_delete(key);
    debug_assert_eq!(r, 0);
}
