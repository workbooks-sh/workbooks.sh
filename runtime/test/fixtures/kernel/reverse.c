/* A source-authored bytes→bytes KERNEL for the hot path (wb-pkh.1). Compiled to a
 * reactor (no _start) by Compilers.c_compile_to_kernel; opened with
 * Workbooks.Kernel.open(bytes, arena: :exports). Reverses its input. The host
 * queries in_ptr/out_ptr (the linker placed these static buffers), writes input at
 * IN, calls process(len), reads len bytes from OUT. */
static unsigned char IN[65536];
static unsigned char OUT[65536];
__attribute__((export_name("in_ptr")))  int in_ptr(void)  { return (int)(long)IN; }
__attribute__((export_name("out_ptr"))) int out_ptr(void) { return (int)(long)OUT; }
__attribute__((export_name("process"))) int process(int len) {
  for (int i = 0; i < len; i++) OUT[len - 1 - i] = IN[i];
  return len;
}
