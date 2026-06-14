# video

Ask for a video, get HyperFrames — a typed, deterministic animation authored against a fixed canvas, which wavelet renders to a clip. The capability is "video"; the implementation is HyperFrames, swappable behind it.

## When to reach for it

Reach for `video` when a user asks for a *video*, *motion graphic*, *animation*, or *ad clip* — don't hand-roll ffmpeg drawtext keyframes or a CSS-animation screen-record. The agent calls the capability and this toolkit resolves it to HyperFrames; for raw still/clip edits (trim/concat/overlay) reach for `ffmpeg` instead — HyperFrames is for *authored motion*.

## Example

A scene module imports the canvas constants and lifecycle from `@work.books/wavelet-hyperframes`:

```js
import { onReady, onTick, CANVAS_WIDTH, CANVAS_HEIGHT, px } from "@work.books/wavelet-hyperframes";
onReady(() => { /* build the scene */ });
onTick((t) => { /* drive it deterministically per frame */ });
// wavelet plays it back + exports the clip (ffmpeg is the encode tail)
```

## What it grants

- An authored-motion surface: `onReady`/`onTick` against a fixed canvas, deterministic per frame.
- Render + export to a clip via wavelet (ffmpeg muxing/encode is the tail, not the authoring surface).

## Maturity

Beta (v0.1.0).
