/* mono — RGBA → grayscale, the reference KERNEL-shape toolkit.
 *
 * The kernel ABI (Workbooks.Kernel, arena: :exports):
 *   - exports `memory` (linker, via --export-memory)
 *   - in_ptr() / out_ptr()        → where the host writes input / reads output
 *   - process(in_len) → out_len   → one call per frame; instance reused
 *
 * Pure compute: no WASI, no imports, no allocation per call. Compiled
 * in-sandbox by clang.wasm (Compilers.c_compile_to_kernel: no crt,
 * --no-entry --export-memory).
 */

#define CAP (1 << 20) /* 1 MiB per side — a frame tile, not a whole video */

static unsigned char in_buf[CAP];
static unsigned char out_buf[CAP];

__attribute__((export_name("in_ptr"))) int in_ptr(void) { return (int)(long)in_buf; }
__attribute__((export_name("out_ptr"))) int out_ptr(void) { return (int)(long)out_buf; }

__attribute__((export_name("process"))) int process(int in_len) {
  if (in_len < 0 || in_len > CAP)
    return 0;

  int quads = in_len / 4;
  for (int i = 0; i < quads; i++) {
    int o = i * 4;
    unsigned char g =
        (unsigned char)((in_buf[o] + in_buf[o + 1] + in_buf[o + 2]) / 3);
    out_buf[o] = g;
    out_buf[o + 1] = g;
    out_buf[o + 2] = g;
    out_buf[o + 3] = in_buf[o + 3]; /* alpha passes through */
  }
  for (int i = quads * 4; i < in_len; i++)
    out_buf[i] = in_buf[i]; /* trailing non-quad bytes pass through */

  return in_len;
}
