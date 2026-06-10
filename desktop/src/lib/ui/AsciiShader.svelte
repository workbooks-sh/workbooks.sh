<script lang="ts">
  /**
   * AsciiShader — the lander's hero background, ported (web/lander
   * index.html): a flowing ASCII char field on a green→blue gradient.
   * Fills its (positioned) parent; respects prefers-reduced-motion by
   * rendering a single static frame.
   */
  import { onMount } from "svelte";

  let { cell = 15 }: { cell?: number } = $props();

  let cv: HTMLCanvasElement | undefined = $state();

  onMount(() => {
    const ctx = cv!.getContext("2d")!;
    const RAMP = " ..::--=+*#%@";
    const G = [63, 224, 129];
    const B = [47, 111, 224];
    let cols = 0;
    let rows = 0;
    let t = 0;
    let running = true;
    let timer: ReturnType<typeof setTimeout> | null = null;

    const resize = () => {
      cv!.width = cv!.offsetWidth;
      cv!.height = cv!.offsetHeight;
      cols = Math.ceil(cv!.width / cell);
      rows = Math.ceil(cv!.height / cell);
      ctx.font = "12px ui-monospace, monospace";
    };

    const frame = () => {
      ctx.clearRect(0, 0, cv!.width, cv!.height);
      for (let y = 0; y < rows; y++) {
        for (let x = 0; x < cols; x++) {
          const n =
            Math.sin(x * 0.19 + t) +
            Math.cos(y * 0.23 - t * 0.7) +
            Math.sin((x + y) * 0.11 + t * 0.5);
          const v = (n + 3) / 6;
          const ch = RAMP[Math.floor(v * (RAMP.length - 1))];
          if (ch === " ") continue;
          const m = Math.min(
            1,
            Math.max(0, (x / cols) * 0.6 + (1 - y / rows) * 0.4 + (v - 0.5) * 0.3),
          );
          const c = G.map((g, i) => Math.round(g * m + B[i] * (1 - m)));
          ctx.fillStyle = `rgba(${c[0]},${c[1]},${c[2]},${(0.04 + v * 0.14).toFixed(3)})`;
          ctx.fillText(ch, x * cell, y * cell + 12);
        }
      }
      t += 0.016;
      if (running) timer = setTimeout(() => requestAnimationFrame(frame), 50);
    };

    resize();
    window.addEventListener("resize", resize);
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduced) {
      running = false;
      frame();
    } else {
      frame();
    }
    return () => {
      running = false;
      if (timer) clearTimeout(timer);
      window.removeEventListener("resize", resize);
    };
  });
</script>

<canvas bind:this={cv} class="ascii" aria-hidden="true"></canvas>

<style>
  .ascii {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    display: block;
  }
</style>
