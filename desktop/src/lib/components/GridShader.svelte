<script lang="ts">
  /**
   * GridShader — the animated graph-paper backdrop. The grid is crisp in the
   * centre and warps/twists subtly toward the screen edges, looping smoothly.
   *
   * Kept deliberately cheap: a single full-screen triangle + a small fragment
   * shader (a few sin/cos + an analytic grid, no textures, no fwidth/extensions),
   * rendered at capped DPR, throttled to ~30fps, paused when the tab is hidden.
   * If WebGL is unavailable the canvas just stays transparent and the CSS grid
   * underneath shows through.
   */
  import { onMount } from "svelte";
  import { chatBackdrop } from "$lib/home/chatBackdrop.svelte";

  let canvas: HTMLCanvasElement;

  const VS = `attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }`;

  // Grid drawn on a domain-warped + slightly-rotated coordinate. The warp +
  // rotation are scaled by `edge` (0 in the centre → 1 at the corners), so the
  // middle stays a clean grid and only the edges twist.
  const FS = `
    precision mediump float;
    uniform vec2 u_res;
    uniform float u_time;
    uniform float u_cell;   // px per grid cell (device px)
    uniform vec3 u_bg;
    uniform vec4 u_line;    // rgba
    uniform float u_chat;   // 0 = normal backdrop, 1 = chat-mode inverted vignette

    float gridMask(vec2 pos, float cellPx) {
      vec2 g = abs(fract(pos / cellPx - 0.5) - 0.5) * cellPx; // px to nearest line
      vec2 m = 1.0 - smoothstep(0.6, 1.6, g);
      return max(m.x, m.y);
    }

    void main() {
      vec2 frag = gl_FragCoord.xy;
      vec2 center = u_res * 0.5;
      vec2 d = (frag - center) / center;          // -1..1 per axis
      float edge = smoothstep(0.4, 1.15, length(d));
      float t = u_time;

      // Very slow, viscous looping warp (px), only felt toward the edges.
      vec2 warp = vec2(
        sin(frag.y * 0.011 + t * 0.16) + 0.5 * sin(frag.x * 0.009 - t * 0.11),
        cos(frag.x * 0.011 + t * 0.14) + 0.5 * cos(frag.y * 0.010 + t * 0.10)
      );
      float amp = u_cell * 0.6 * edge;

      // Gentle, slow rotation about the centre, edge-weighted.
      float ang = edge * 0.16 * sin(t * 0.06);
      vec2 rd = frag - center;
      vec2 rot = vec2(rd.x * cos(ang) - rd.y * sin(ang),
                      rd.x * sin(ang) + rd.y * cos(ang));

      vec2 pos = center + rot + warp * amp;
      float mask = gridMask(pos, u_cell);
      // Normal backdrop: faint, fainter toward the edges (crisp in the middle).
      float aNormal = 0.12 * (1.0 - edge * 0.6);
      // Chat mode (FIX 3): INVERTED vignette — clear centre, faint grid only at
      // the edges. r is the normalized radius (0 centre to 1 corner); the grid
      // ramps in from a clear hole behind the conversation out to the rim.
      float r = length(d);
      float ring = smoothstep(0.45, 1.05, r);
      float aChat = 0.13 * ring;
      float a = mix(aNormal, aChat, u_chat);
      vec3 col = mix(u_bg, u_line.rgb, a * mask);
      gl_FragColor = vec4(col, 1.0);
    }
  `;

  onMount(() => {
    const gl = canvas.getContext("webgl", { alpha: false, antialias: false, depth: false, stencil: false });
    if (!gl) return; // CSS grid fallback remains visible

    function sh(type: number, src: string) {
      const s = gl!.createShader(type)!;
      gl!.shaderSource(s, src);
      gl!.compileShader(s);
      return s;
    }
    const prog = gl.createProgram()!;
    gl.attachShader(prog, sh(gl.VERTEX_SHADER, VS));
    gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FS));
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return;
    gl.useProgram(prog);

    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(prog, "p");
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

    const U = {
      res: gl.getUniformLocation(prog, "u_res"),
      time: gl.getUniformLocation(prog, "u_time"),
      cell: gl.getUniformLocation(prog, "u_cell"),
      bg: gl.getUniformLocation(prog, "u_bg"),
      line: gl.getUniformLocation(prog, "u_line"),
      chat: gl.getUniformLocation(prog, "u_chat"),
    };
    // Eased chat-mode amount — ramps toward chatBackdrop.active so the
    // vignette inverts in (and back out) smoothly instead of snapping.
    let chatAmt = 0;

    // Resolve theme colours from CSS vars via a 2D canvas (normalises hex/rgb/rgba).
    const probe = document.createElement("canvas").getContext("2d")!;
    function rgba(v: string): [number, number, number, number] {
      probe.fillStyle = "#000";
      probe.fillStyle = v.trim() || "#000";
      const s = probe.fillStyle as string;
      if (s[0] === "#") {
        const h = s.length === 4
          ? s.slice(1).split("").map((c) => parseInt(c + c, 16))
          : [parseInt(s.slice(1, 3), 16), parseInt(s.slice(3, 5), 16), parseInt(s.slice(5, 7), 16)];
        return [h[0] / 255, h[1] / 255, h[2] / 255, 1];
      }
      const m = s.match(/[\d.]+/g)!.map(Number);
      return [m[0] / 255, m[1] / 255, m[2] / 255, m[3] ?? 1];
    }
    let scale = 1;
    function readColors() {
      const cs = getComputedStyle(document.documentElement);
      // Use concrete tokens — --color-chrome is a color-mix() expression that
      // getPropertyValue returns UNRESOLVED, so it can't be parsed (it fell
      // back to black, which is why the backdrop stayed dark in light mode).
      const bg = rgba(cs.getPropertyValue("--color-page") || "#f7f6f1");
      const line = rgba(cs.getPropertyValue("--color-grid-line") || "rgba(18,19,22,0.07)");
      const cellCss = parseFloat(cs.getPropertyValue("--grid-size")) || 22;
      gl!.uniform3f(U.bg, bg[0], bg[1], bg[2]);
      gl!.uniform4f(U.line, line[0], line[1], line[2], line[3]);
      gl!.uniform1f(U.cell, cellCss * scale);
    }
    function resize() {
      scale = Math.min(window.devicePixelRatio || 1, 2);
      const w = Math.round(window.innerWidth * scale);
      const h = Math.round(window.innerHeight * scale);
      canvas.width = w;
      canvas.height = h;
      gl!.viewport(0, 0, w, h);
      gl!.uniform2f(U.res, w, h);
      readColors();
    }
    resize();

    let raf = 0;
    let last = -1e9;
    let ticks = 0;
    const interval = 1000 / 30; // ~30fps cap
    function frame(now: number) {
      raf = requestAnimationFrame(frame);
      if (document.hidden || now - last < interval) return;
      last = now;
      // Self-heal the theme colours every ~0.5s. The data-mode observer can
      // miss a flip when the canvas reveals mid-onboarding (it mounts hidden,
      // then the theme beat both reveals it AND changes the mode), which left
      // u_bg on its dark default → a pure-black backdrop in light mode. A
      // cheap periodic re-read guarantees the backdrop always tracks the theme.
      if (ticks++ % 15 === 0) readColors();
      // Ease toward the chat-mode target (~0.4s in/out at this 30fps cap).
      const target = chatBackdrop.active ? 1 : 0;
      chatAmt += (target - chatAmt) * 0.12;
      if (Math.abs(target - chatAmt) < 0.001) chatAmt = target;
      gl!.uniform1f(U.chat, chatAmt);
      gl!.uniform1f(U.time, now * 0.001);
      gl!.drawArrays(gl!.TRIANGLES, 0, 3);
    }
    raf = requestAnimationFrame(frame);

    window.addEventListener("resize", resize);
    const moDark = new MutationObserver(readColors);
    moDark.observe(document.documentElement, { attributes: true, attributeFilter: ["data-mode"] });
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    mq.addEventListener("change", readColors);

    return () => {
      cancelAnimationFrame(raf);
      window.removeEventListener("resize", resize);
      moDark.disconnect();
      mq.removeEventListener("change", readColors);
      gl.getExtension("WEBGL_lose_context")?.loseContext();
    };
  });
</script>

<canvas bind:this={canvas} class="grid-shader" aria-hidden="true"></canvas>

<style>
  .grid-shader {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    z-index: 0; /* above the shell's CSS-grid fallback, below the content */
    pointer-events: none;
    display: block;
  }
</style>
