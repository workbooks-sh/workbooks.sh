[target]
family = ""
os-name = "wasi"
env-name = ""

[backend.c]
variant = "gnu"
emulate-i128 = true
target = "wasm32-wasi"
compiler-opts = ["-ffunction-sections",]
linker-opts-pre = []
linker-opts-post = ["-Wl,--gc-sections",]

[arch]
name = "wasm32"
pointer-bits = 32
is-big-endian = false
has-atomic-u8 = true
has-atomic-u16 = false
has-atomic-u32 = true
has-atomic-u64 = false
has-atomic-ptr = true
alignments = { u16 = 2, u32 = 4, u64 = 8, u128 = 16, f32 = 4, f64 = 8, ptr = 4 }
