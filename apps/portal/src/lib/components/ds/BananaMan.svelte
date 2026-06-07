<!--
  BananaMan — sprite-sheet banana mascot that idles, faces the cursor,
  reacts ("wowza!") when the cursor wanders far after a long idle, walks
  toward it, and splits when you hover him.

  Sprite sheet: /banana-man.png  (128 × 288 = 4 cols × 9 rows × 32×32 frames).
  Active rows (others ignored):
    0  idle   (4 frames) — standing loop, faces cursor
    1  walk   (4 frames) — single cycle, used while moving toward cursor
    3  wowza  (4 frames) — pre-chase reaction: full 0→3 cycle once, then walk.
                            Triggered when cursor wanders past chaseDistance
                            AFTER he's been idle for idleReactMs.
    4  split  (4 frames) — hover effect: forward + hold at peak.
                            Reverses 3→0 on hover-out.

  Parent must be position: relative — the component absolutely positions inside.
-->
<script lang="ts">
  import { onMount } from "svelte";

  interface Props {
    /** Pixel size to render at (frames are 32×32 native; default 3× = 96px). */
    scale?: number;
    /** Locomotion speed in px/sec. */
    speed?: number;
    /** Container offset from the top of the parent (negative lifts him up). */
    topOffset?: number;
    /** Horizontal cursor distance before he starts chasing (px). */
    chaseDistance?: number;
    /** How long he must be idle before the next chase triggers a wowza (ms). */
    idleReactMs?: number;
  }
  let {
    scale = 3,
    speed = 140,
    topOffset = -72,
    chaseDistance = 160,
    idleReactMs = 1800,
  }: Props = $props();

  const FRAME_PX = 32;
  const SIZE = FRAME_PX * scale;
  const SHEET_W = FRAME_PX * 4;
  const SHEET_H = FRAME_PX * 9;

  type AnimKey = "idle" | "walk" | "wowza" | "split" | "split-reverse";

  const ANIMS: Record<AnimKey, { row: number; frames: number; fps: number }> = {
    idle:            { row: 0, frames: 4, fps: 4 },
    walk:            { row: 1, frames: 4, fps: 9 },
    wowza:           { row: 3, frames: 4, fps: 10 }, // pre-chase reaction only
    split:           { row: 4, frames: 4, fps: 10 }, // hover forward + hold
    "split-reverse": { row: 4, frames: 4, fps: 12 }, // un-hover reverse
  };

  let container = $state<HTMLDivElement | null>(null);
  let trackWidth = $state(800);
  let posX = $state(40);
  let facingRight = $state(true);

  let anim = $state<AnimKey>("idle");
  let frame = $state(0);
  let hovered = $state(false);

  // Idle bookkeeping: when did we last enter the idle state? Used to decide
  // whether the next chase should pre-roll a wowza reaction.
  let idleSinceT = $state(0);

  let cursorX = $state(400);
  let cursorY = $state(0);
  let containerRect = { top: 0, left: 0, width: 0, height: 0 };

  function recomputeRect() {
    if (!container) return;
    const r = container.getBoundingClientRect();
    containerRect = { top: r.top, left: r.left, width: r.width, height: r.height };
    trackWidth = r.width;
  }
  function onMouseMove(e: MouseEvent) {
    cursorX = e.clientX - containerRect.left;
    cursorY = e.clientY - containerRect.top;
  }

  let rafId = 0;
  let lastT = 0;
  let lastFrameT = 0;

  function loop(t: number) {
    if (!lastT) lastT = t;
    const dt = (t - lastT) / 1000;
    lastT = t;
    const now = t;

    const margin = 24;
    const targetX = Math.max(
      margin,
      Math.min(trackWidth - margin - SIZE, cursorX - SIZE / 2),
    );
    const dx = targetX - posX;
    const absDx = Math.abs(dx);

    // Banana can't see what's below him — if the cursor dips below the
    // sprite's bottom, treat the world as quiet (no facing update, no chase).
    const cursorBelow = cursorY > SIZE;

    // Always face the cursor when it's a real direction (not when hovered —
    // cursor is right on the sprite then and dx noise would flip flapping —
    // and not when the cursor is below him).
    if (!hovered && !cursorBelow && absDx > 20) {
      facingRight = dx > 0;
    }

    // -- Hover state (highest priority) — split animation -------------------
    if (hovered) {
      if (anim !== "split") {
        // Enter split. If we were mid-reverse, keep the current frame so the
        // transition stays seamless.
        const startFrame = anim === "split-reverse" ? frame : 0;
        anim = "split";
        frame = startFrame;
      }
    } else if (anim === "split") {
      anim = "split-reverse";
    }

    // -- Cursor-driven locomotion (only if not splitting / wowza-ing) -------
    if (anim !== "split" && anim !== "split-reverse" && anim !== "wowza") {
      if (cursorBelow) {
        // Banana can't see down — stay idle, ignore cursor distance.
        if (anim !== "idle") {
          anim = "idle";
          frame = 0;
          idleSinceT = now;
        }
      } else if (absDx > chaseDistance) {
        // Cursor wandered far enough to chase. If we'd been idle for a while,
        // do a "wowza!" reaction first; otherwise start walking immediately.
        const idledLong = anim === "idle" && now - idleSinceT >= idleReactMs;
        if (idledLong) {
          anim = "wowza";
          frame = 0;
        } else {
          if (anim !== "walk") {
            anim = "walk";
            frame = 0;
          }
          const step = Math.sign(dx) * Math.min(absDx, speed * dt);
          posX += step;
        }
      } else {
        // Close enough — idle (and stamp when we entered idle).
        if (anim !== "idle") {
          anim = "idle";
          frame = 0;
          idleSinceT = now;
        }
      }
    }

    // -- Frame advance ------------------------------------------------------
    const a = ANIMS[anim];
    if (a.frames > 1 && now - lastFrameT >= 1000 / a.fps) {
      if (anim === "wowza") {
        // Pre-chase: play 0→3 once, then start walking.
        if (frame < a.frames - 1) {
          frame += 1;
        } else {
          anim = "walk";
          frame = 0;
        }
      } else if (anim === "split") {
        // Hover: forward, hold at peak.
        if (frame < a.frames - 1) frame += 1;
      } else if (anim === "split-reverse") {
        // Hover-out: reverse to 0, then resume cursor-driven state.
        if (frame > 0) {
          frame -= 1;
        } else {
          if (absDx > chaseDistance) {
            anim = "walk";
            frame = 0;
          } else {
            anim = "idle";
            frame = 0;
            idleSinceT = now;
          }
        }
      } else {
        frame = (frame + 1) % a.frames;
      }
      lastFrameT = now;
    }

    rafId = requestAnimationFrame(loop);
  }

  onMount(() => {
    recomputeRect();
    window.addEventListener("mousemove", onMouseMove, { passive: true });
    window.addEventListener("resize", recomputeRect);
    window.addEventListener("scroll", recomputeRect, { passive: true });
    rafId = requestAnimationFrame(loop);
    posX = Math.max(40, trackWidth / 4);
    idleSinceT = performance.now();
    return () => {
      cancelAnimationFrame(rafId);
      window.removeEventListener("mousemove", onMouseMove);
      window.removeEventListener("resize", recomputeRect);
      window.removeEventListener("scroll", recomputeRect);
    };
  });
</script>

<div
  bind:this={container}
  class="absolute left-0 right-0 pointer-events-none"
  style="height: {SIZE}px; top: {topOffset}px;"
  aria-hidden="true"
>
  <div
    onmouseenter={() => (hovered = true)}
    onmouseleave={() => (hovered = false)}
    role="presentation"
    class="absolute pointer-events-auto bg-no-repeat"
    style="
      left: {posX}px;
      top: 0;
      width: {SIZE}px;
      height: {SIZE}px;
      background-image: url('/banana-man.png');
      background-size: {SHEET_W * scale}px {SHEET_H * scale}px;
      background-position: -{frame * FRAME_PX * scale}px -{ANIMS[anim].row * FRAME_PX * scale}px;
      image-rendering: pixelated;
      transform: scaleX({facingRight ? 1 : -1});
      transform-origin: center;
    "
  ></div>
</div>
