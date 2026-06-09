// Workbooks lander — built as a workbook, compiled by @work.books/cli.
// Two behaviors: (1) a colored ASCII shader (canvas, cheap + throttled,
// pauses when offscreen) used as the signature modern-tech element, and
// (2) the live invoice tracker that proves the page is a real app.

const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
const $ = (s, r = document) => r.querySelector(s);

/* ───────────────────────── ASCII shader ─────────────────────────
   Flat, modern, multi-color. A plasma field sampled onto a character
   ramp; each cell tinted across the brand stops. ~20fps, Intersection-
   paused, single static frame under reduced-motion. */
const RAMP = " ·:-=+*o#%@";
function hexToRgb(h){const n=parseInt(h.slice(1),16);return[n>>16&255,n>>8&255,n&255];}
function lerp(a,b,t){return a+(b-a)*t;}
function mixStops(stops,t){
  const seg=(stops.length-1)*Math.min(0.999,Math.max(0,t));
  const i=Math.floor(seg),f=seg-i,a=stops[i],b=stops[i+1]||stops[i];
  return `rgb(${lerp(a[0],b[0],f)|0},${lerp(a[1],b[1],f)|0},${lerp(a[2],b[2],f)|0})`;
}

function asciiShader(canvas){
  const light = canvas.dataset.mode === "light";   // transparent → sits on white
  const skip = canvas.dataset.dense !== undefined ? 0.34 : 0.5; // light-mode density floor
  const ctx = canvas.getContext("2d", { alpha: light });
  const stops = (canvas.dataset.colors || "#00ff44,#0080ff,#ff0066").split(",").map(s=>hexToRgb(s.trim()));
  const bg = canvas.dataset.bg || "#0c0c0e";
  const speed = parseFloat(canvas.dataset.speed || "1");
  const cw = 9, ch = 15;                 // monospace cell metrics @ 13px
  let cols=0, rows=0, dpr=Math.min(2, devicePixelRatio||1);

  function resize(){
    const r = canvas.getBoundingClientRect();
    cols = Math.max(8, Math.floor(r.width / cw));
    rows = Math.max(6, Math.floor(r.height / ch));
    canvas.width = Math.floor(r.width*dpr);
    canvas.height = Math.floor(r.height*dpr);
    ctx.setTransform(dpr,0,0,dpr,0,0);
    ctx.font = "13px 'Spline Sans Mono', ui-monospace, monospace";
    ctx.textBaseline = "top";
  }
  function draw(t){
    const w = canvas.width/dpr, h = canvas.height/dpr;
    if(light){ ctx.clearRect(0,0,w,h); } else { ctx.fillStyle = bg; ctx.fillRect(0,0,w,h); }
    const time = t*0.001*speed;
    for(let y=0;y<rows;y++){
      for(let x=0;x<cols;x++){
        const v = (
          Math.sin(x*0.28 + time) +
          Math.sin(y*0.22 - time*1.2) +
          Math.sin((x+y)*0.16 + time*0.8) +
          Math.sin(Math.hypot(x-cols/2, y-rows/2)*0.3 - time*1.4)
        ) / 4;                            // -1..1
        const n = (v+1)/2;                // 0..1
        const ci = Math.floor(n*(RAMP.length-1));
        const chr = RAMP[ci];
        if(chr===" " || (light && n < skip)) continue;   // sparser on white
        ctx.fillStyle = mixStops(stops, n);
        ctx.fillText(chr, x*cw, y*ch);
      }
    }
  }

  resize();
  if(reduceMotion){ draw(1000); return; }     // one static frame
  let raf=null, running=false, lastT=0;
  const FRAME = 1000/20;                        // throttle to 20fps
  function loop(t){ if(t-lastT>=FRAME){ draw(t); lastT=t; } raf=requestAnimationFrame(loop); }
  const io = new IntersectionObserver(es=>{
    for(const e of es){
      if(e.isIntersecting && !running){ running=true; raf=requestAnimationFrame(loop); }
      else if(!e.isIntersecting && running){ running=false; cancelAnimationFrame(raf); }
    }
  },{threshold:0});
  io.observe(canvas);
  let rz; addEventListener("resize",()=>{clearTimeout(rz);rz=setTimeout(resize,150);});
}
document.querySelectorAll("canvas.ascii").forEach(asciiShader);

/* ───────────────────────── live invoice app ───────────────────── */
const listEl = $("#list"), totalEl = $("#total"), addBtn = $("#add");
if(listEl && totalEl){
  const money = n => "$" + n.toLocaleString("en-US");
  const NEW = [["Cedar & Co.",1800],["Bright Harbor",2600],["Atlas Works",1400],["Quill Design",3000]];
  let added = 0;
  function recompute(flash=true){
    let owed=0; listEl.querySelectorAll("li").forEach(li=>{ if(li.dataset.paid!=="true") owed+=+li.dataset.amt||0; });
    totalEl.textContent = money(owed);
    if(flash && !reduceMotion){ totalEl.classList.remove("flash"); void totalEl.offsetWidth; totalEl.classList.add("flash"); }
  }
  listEl.addEventListener("click", e=>{
    const b=e.target.closest(".pay"); if(!b) return;
    const li=b.closest("li"); if(li.dataset.paid==="true") return;
    li.dataset.paid="true"; b.textContent="Paid"; recompute();
  });
  addBtn?.addEventListener("click", ()=>{
    const [who,amt]=NEW[added++%NEW.length];
    const li=document.createElement("li");
    li.dataset.amt=String(amt); li.dataset.paid="false"; li.className="added";
    li.innerHTML=`<span class="who"></span><span class="amt"></span><button class="pay" type="button">Mark paid</button>`;
    $(".who",li).textContent=who; $(".amt",li).textContent=money(amt);
    listEl.appendChild(li); recompute();
  });
  recompute(false);
}
