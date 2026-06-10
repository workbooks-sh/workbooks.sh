<script>
  import { insp, openInsp, closeInsp } from "./inspector.svelte.js";
  let tree = $state("");
  let treeBuilt = false;
  const esc = s => (s||"").replace(/[&<>]/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;"}[c]));

  function buildTree(){
    if(treeBuilt) return; treeBuilt = true;
    const squash=(s,n=80)=>{s=(s||"").replace(/\s+/g," ").trim();return s.length>n?s.slice(0,n)+"…":s;};
    const VOID=["meta","link","br","img","input","hr","source","path","use"];
    const OPAQUE=["script","style","svg","canvas","iframe"];
    const out=[];
    function attrs(n){let a="";for(const at of n.attributes){let v=at.value;if(v.length>32)v=v.slice(0,26)+"…";a+=` <span class="an">${esc(at.name)}</span>=<span class="av">"${esc(v)}"</span>`;}return a;}
    function walk(node,depth){
      if(node.nodeType===8){out.push(`<div class="row cm leaf">&lt;!-- ${esc(squash(node.textContent,110))} --&gt;</div>`);return;}
      if(node.nodeType===3){const t=squash(node.textContent);if(t)out.push(`<div class="row tx leaf">${esc(t)}</div>`);return;}
      if(node.nodeType!==1)return;
      if(["insp","insp-handle"].includes(node.id))return;
      const tag=node.tagName.toLowerCase();
      const kids=[...node.childNodes].filter(n=>n.nodeType===1||n.nodeType===8||(n.nodeType===3&&n.textContent.trim()));
      const open=`<span class="t">&lt;${tag}</span>${attrs(node)}<span class="t">&gt;</span>`;
      if(VOID.includes(tag)){out.push(`<div class="row leaf">${open}</div>`);return;}
      if(!kids.length){out.push(`<div class="row leaf">${open}<span class="t">&lt;/${tag}&gt;</span></div>`);return;}
      const opaque=OPAQUE.includes(tag);
      const collapsed=(opaque||depth>=2)?" collapsed":"";
      out.push(`<div class="node${collapsed}">`);
      out.push(`<div class="row open"><span class="caret">▾</span>${open}<span class="tail"><span class="cm">…</span><span class="t">&lt;/${tag}&gt;</span></span></div>`);
      out.push(`<div class="children">`);
      if(opaque)out.push(`<div class="row cm leaf">…</div>`);
      else if(depth<8)kids.forEach(k=>walk(k,depth+1));
      out.push(`</div>`);
      out.push(`<div class="row close"><span class="t">&lt;/${tag}&gt;</span></div></div>`);
    }
    out.push(`<div class="row cm leaf">&lt;!DOCTYPE html&gt;</div>`);
    walk(document.documentElement,0);
    tree=out.join("");
  }
  function onTreeClick(e){ const open=e.target.closest(".row.open"); if(open) open.parentElement.classList.toggle("collapsed"); }
  $effect(() => { if(insp.open && insp.tab==="elements") buildTree(); });
  function tab(name){ insp.tab=name; if(name==="elements") buildTree(); }
</script>

{#if !insp.open}
  <button class="handle" id="insp-handle" onclick={() => openInsp("elements")}>⌗ inspect</button>
{/if}

<aside class="dt" class:open={insp.open} aria-label="workbook inspector">
  <div class="bar">
    <span class="icons">⌖ ▢</span>
    <div class="tabs">
      <button class:on={insp.tab==="elements"} onclick={() => tab("elements")}>HTML</button>
      <button class:on={insp.tab==="console"} onclick={() => tab("console")}>Agent log</button>
      <button class:on={insp.tab==="about"} onclick={() => tab("about")}>About</button>
    </div>
    <button class="x" onclick={closeInsp} aria-label="Close">✕</button>
  </div>

  {#if insp.tab==="elements"}
    <div class="hint">The live HTML of this page — one file, the whole app. Click ▸ to fold a node.</div>
    <div class="tree" onclick={onTreeClick}>{@html tree}</div>
    <div class="crumbs">html › body › section</div>
  {:else if insp.tab==="console"}
    <div class="hint">What the agent did to build and maintain this page.</div>
    <div class="log">
      {#each insp.log as l}<div class="ln {l.cls}">{@html l.html}</div>{/each}
    </div>
  {:else}
    <div class="about">
      <p>This page is composed and maintained by an agent, <b>lander-keeper</b>, on the Workbooks engine. It reads the page on a schedule, makes one constrained change, and commits it — so the changelog below <em>is</em> its work, live.</p>
      <h4>ground rules</h4>
      <div class="rule">· never fabricate users, metrics, or praise</div>
      <div class="rule">· one constrained edit per run · always reversible</div>
      <div class="rule">· never remove the download or this inspector</div>
      <h4>changelog <span class="badge">{insp.changes.length ? insp.changes.length + " commits · live" : "live · /_changes"}</span></h4>
      {#if insp.changes.length}
        {#each insp.changes.slice(0,14) as c}<div class="clrow"><code>{c.sha.slice(0,7)}</code><span>{c.msg}</span></div>{/each}
      {:else}<div class="clrow"><span>loading…</span></div>{/if}
    </div>
  {/if}
</aside>

<style>
  .handle{position:fixed;right:1rem;bottom:1rem;z-index:80;font-family:var(--mono);font-size:.74rem;
    background:#1f1f22;color:#cfd2d6;border:1px solid #34363b;border-radius:8px;padding:.5rem .8rem;cursor:pointer;box-shadow:0 10px 28px -14px rgba(0,0,0,.6)}
  .handle:hover{color:#fff;border-color:#4a4c52}
  .dt{position:fixed;top:0;right:0;bottom:0;width:var(--dt-w,min(460px,46vw));z-index:78;display:flex;flex-direction:column;
    background:#1c1c1f;color:#d4d4d4;border-left:1px solid #000;font-family:var(--mono);font-size:12px;line-height:1.5;
    transform:translateX(100%);transition:transform .35s cubic-bezier(.2,.7,.2,1)}
  .dt.open{transform:none}
  .bar{display:flex;align-items:center;gap:.5rem;height:37px;padding:0 .5rem;background:#28282b;border-bottom:1px solid #000;flex:none}
  .icons{color:#9aa0a6;padding-right:.45rem;border-right:1px solid #3a3a3d}
  .tabs{display:flex;gap:.05rem;flex:1}
  .tabs button{background:none;border:0;color:#9aa0a6;font-family:inherit;font-size:12px;padding:.45rem .6rem;cursor:pointer;border-bottom:2px solid transparent}
  .tabs button:hover{color:#e8e8e8} .tabs button.on{color:#fff;border-bottom-color:#8ab4f8}
  .x{background:none;border:0;color:#9aa0a6;cursor:pointer;font-size:13px}.x:hover{color:#fff}
  .hint{font-size:11px;color:#83878d;padding:.5rem .7rem;border-bottom:1px solid #2a2a2d;line-height:1.4;flex:none}
  .tree{flex:1;overflow:auto;padding:.55rem .7rem;font-size:11.5px}
  .crumbs{flex:none;height:27px;display:flex;align-items:center;padding:0 .7rem;background:#28282b;border-top:1px solid #000;color:#9aa0a6;font-size:11px}
  .tree :global(.children){padding-left:1.05rem}
  .tree :global(.row){position:relative;padding:1px 0 1px 1.1rem;white-space:pre-wrap;word-break:break-word}
  .tree :global(.row.open){cursor:pointer;border-radius:3px}
  .tree :global(.row.open:hover){background:#2a2a2d}
  .tree :global(.caret){position:absolute;left:0;width:1rem;text-align:center;color:#9aa0a6;font-size:9px;display:inline-block;transition:transform .12s}
  .tree :global(.node.collapsed > .row.open .caret){transform:rotate(-90deg)}
  .tree :global(.node.collapsed > .children),.tree :global(.node.collapsed > .row.close){display:none}
  .tree :global(.tail){display:none}
  .tree :global(.node.collapsed > .row.open .tail){display:inline}
  .tree :global(.t){color:#5db0d7} .tree :global(.an){color:#9bbbdc} .tree :global(.av){color:#f29766} .tree :global(.cm){color:#7a7a7a;font-style:italic} .tree :global(.tx){color:#a8a8a8}
  .log{flex:1;overflow:auto;padding:.55rem .7rem;font-size:11.5px}
  .ln{padding:.2rem 0;border-bottom:1px solid #2a2a2d;color:#cfd2d6}
  .ln :global(.pr){color:#7ad97a;font-weight:700} .ln :global(.kw){color:#8ab4f8} .ln :global(.ok){color:#7ad97a} .ln :global(.dim){color:#777}
  .about{flex:1;overflow:auto;padding:.8rem .7rem}
  .about p{color:#b8b8b8;font-size:12px} .about b{color:#fff} .about em{color:#fff;font-style:italic}
  .about h4{color:#9aa0a6;font-size:10px;text-transform:uppercase;letter-spacing:.1em;margin:1rem 0 .45rem}
  .rule{color:#b0b0b0;padding:.16rem 0}
  .badge{color:#7ad97a;background:#22351f;padding:.1rem .45rem;border-radius:999px;font-size:10px;margin-left:.3rem}
  .clrow{display:flex;gap:.6rem;padding:.25rem 0} .clrow code{color:#7ad97a;flex:none} .clrow span{color:#cfd2d6}
</style>
