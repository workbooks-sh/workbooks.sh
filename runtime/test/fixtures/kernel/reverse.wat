;; A minimal bytes→bytes "kernel" for the hot invocation path (wb-rhs.5).
;; Fixed in/out ARENA: caller writes input at IN (1024), calls process(len),
;; reads `len` bytes of output from OUT (65536). Reverses the bytes. The arena
;; is reused across calls — no per-frame allocation, no stdio.
(module
  (memory (export "memory") 2)            ;; 128 KiB
  (func (export "process") (param $len i32) (result i32)
    (local $i i32)
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $len)))
        (i32.store8
          (i32.add (i32.const 65536)
                   (i32.sub (i32.sub (local.get $len) (i32.const 1)) (local.get $i)))
          (i32.load8_u (i32.add (i32.const 1024) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (local.get $len)))
