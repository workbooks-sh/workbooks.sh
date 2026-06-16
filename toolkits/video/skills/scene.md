# scene — author a HyperFrames video scene

# scene — author motion as a HyperFrames scene
  A video is a deterministic, typed animation against a fixed canvas — authored,
  not screen-recorded. Author it with `@work.books/wavelet-hyperframes`.

  The shape:
```ts
  import { onReady, onTick, CANVAS_WIDTH, CANVAS_HEIGHT, px } from "@work.books/wavelet-hyperframes";

  onReady(({ ctx }) => {
    // build the scene once: layers, text, product image, palette
  });

  onTick(({ ctx, t }) => {
    // drive it deterministically by time t — every frame is a pure fn of t,
    // so renders are reproducible. Hard cuts between beats; no fade/wipe.
  });
```

  Rules: the canvas is fixed (`CANVAS_WIDTH/HEIGHT`, `CANVAS_ASPECT`); use `px()`
  for DPR-correct units; keep `onTick` a pure function of `t` (no wall-clock,
  no random — reproducible renders). For an ad without dialogue, frame the
  PRODUCT, not a person. Then render the scene with the `render-export` skill.
