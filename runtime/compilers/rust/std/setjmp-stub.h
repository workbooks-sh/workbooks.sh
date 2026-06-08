// wb-49z: stub setjmp for the panic=abort wasm lane. mrustc's C output #includes <setjmp.h>;
// the wasi-sdk header #errors w/o -fwasm-exceptions/sjlj. With panic=abort, longjmp is never
// reached (panic aborts), so no-op setjmp + trap-longjmp is safe → no exceptions proposal needed
// → runs under stock wasmtime + Wasmex (no engine exceptions flag).
#ifndef _WB_SETJMP_STUB
#define _WB_SETJMP_STUB
typedef int jmp_buf[1];
static inline int setjmp(jmp_buf b){(void)b;return 0;}
__attribute__((noreturn)) static inline void longjmp(jmp_buf b,int v){(void)b;(void)v;__builtin_trap();}
#endif
