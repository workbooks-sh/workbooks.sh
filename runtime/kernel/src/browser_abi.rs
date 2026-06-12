//! Browser ABI — a minimal ptr/len boundary for wasm32-unknown-unknown,
//! so the SAME kernel runs directly in a web page (the learn notebooks).
//! Contained unsafe: alloc/dealloc shims + string in, packed-u64 out
//! (high 32 bits = ptr, low 32 = len). The logic is the pure API in lib.rs —
//! there is still no "wasm version" of the kernel.

use std::alloc::{alloc, dealloc, Layout};

#[no_mangle]
pub extern "C" fn oql_alloc(len: usize) -> *mut u8 {
    unsafe { alloc(Layout::from_size_align_unchecked(len.max(1), 1)) }
}

#[no_mangle]
pub extern "C" fn oql_dealloc(ptr: *mut u8, len: usize) {
    unsafe { dealloc(ptr, Layout::from_size_align_unchecked(len.max(1), 1)) }
}

fn pack(s: String) -> u64 {
    let bytes = s.into_bytes();
    let len = bytes.len();
    let ptr = oql_alloc(len);
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr, len) };
    ((ptr as u64) << 32) | (len as u64)
}

unsafe fn arg(ptr: *const u8, len: usize) -> String {
    String::from_utf8_lossy(std::slice::from_raw_parts(ptr, len)).into_owned()
}

macro_rules! export {
    ($name:ident, $func:path) => {
        #[no_mangle]
        pub extern "C" fn $name(ptr: *const u8, len: usize) -> u64 {
            pack($func(&unsafe { arg(ptr, len) }))
        }
    };
}

export!(oql_parse_headlines, crate::parse_headlines);
export!(oql_tangle_plan, crate::tangle_plan);
export!(oql_validate, crate::validate);
export!(oql_render, crate::render);
