<script>
  import { onMount } from "svelte";
  import { theme } from "./theme.svelte.js";
  let { dense = false, speed = 0.7, klass = "" } = $props();
  let canvas;
  const RAMP = " ·:-=+*o#%@";
  const hex = h => { const n = parseInt(h.slice(1), 16); return [n>>16&255, n>>8&255, n&255]; };
  const PAL = { dark:[hex("#00ff44"),hex("#0080ff"),hex("#ff0066")], light:[hex("#0a9d44"),hex("#0a6fe6"),hex("#e0005c")] };
  const mix = (s,t)=>{const seg=(s.length-1)*Math.min(.999,Math.max(0,t));const i=Math.floor(seg),f=seg-i,a=s[i],b=s[i+1]||s[i];return `rgb(${a[0]+(b[0]-a[0])*f|0},${a[1]+(b[1]-a[1])*f|0},${a[2]+(b[2]-a[2])*f|0})`;};
  onMount(() => {
    const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
    const ctx = canvas.getContext("2d", { alpha:true });
    const cw=9, ch=15, dpr=Math.min(2, devicePixelRatio||1);
    let cols, rows, stops, skip, raf, running=false, last=0;
    function th(){ const d=theme.mode==="dark"; stops=PAL[d?"dark":"light"]; skip=d?(dense?.22:.38):(dense?.12:.26); }
    function resize(){ const r=canvas.getBoundingClientRect(); cols=Math.max(8,Math.floor(r.width/cw)); rows=Math.max(4,Math.floor(r.height/ch));
      canvas.width=r.width*dpr; canvas.height=r.height*dpr; ctx.setTransform(dpr,0,0,dpr,0,0); ctx.font="13px 'Spline Sans Mono',monospace"; ctx.textBaseline="top"; }
    function draw(t){ ctx.clearRect(0,0,canvas.width/dpr,canvas.height/dpr); const T=t*.001*speed;
      for(let y=0;y<rows;y++)for(let x=0;x<cols;x++){ const v=(Math.sin(x*.28+T)+Math.sin(y*.22-T*1.2)+Math.sin((x+y)*.16+T*.8)+Math.sin(Math.hypot(x-cols/2,y-rows/2)*.3-T*1.4))/4; const n=(v+1)/2;
        const c=RAMP[Math.floor(n*(RAMP.length-1))]; if(c===" "||n<skip)continue; ctx.fillStyle=mix(stops,n); ctx.fillText(c,x*cw,y*ch); } }
    th(); resize(); draw(0);
    $effect(() => { theme.mode; th(); draw(performance.now()); });
    if(reduce){ draw(1000); return; }
    const loop=t=>{ if(t-last>=50){draw(t);last=t;} raf=requestAnimationFrame(loop); };
    const io=new IntersectionObserver(es=>es.forEach(e=>{ if(e.isIntersecting&&!running){running=true;raf=requestAnimationFrame(loop);} else if(!e.isIntersecting&&running){running=false;cancelAnimationFrame(raf);} }));
    io.observe(canvas);
    let rz; const onR=()=>{clearTimeout(rz);rz=setTimeout(resize,150);}; addEventListener("resize",onR);
    return ()=>{ cancelAnimationFrame(raf); io.disconnect(); removeEventListener("resize",onR); };
  });
</script>
<canvas bind:this={canvas} class={klass} aria-hidden="true"></canvas>
<style>canvas{display:block;width:100%;height:100%}</style>
