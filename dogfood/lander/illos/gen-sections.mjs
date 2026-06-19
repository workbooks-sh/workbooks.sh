import { writeFileSync } from "node:fs";
const KEY = process.env.OPENROUTER_API_KEY;
const CANON = `1970s retrofuturist science-fiction illustration in the spirit of French sci-fi comic masters like Moebius and 70s airbrush poster art: fine clean ink linework, forms modeled with soft airbrushed gradients and gentle volumetric shading, dimensional and calm, rich print grain and subtle vintage paper texture, saturated but refined limited palette, small figures against monumental forms, generous luminous sky with empty space. Bright and light — no nighttime, no dark background. Not flat vector art, not screen-print, no photorealism, no 3D render, no text or lettering. Wide cinematic 16:9 panoramic composition.`;
const JOBS = [
  { name: "hero-desktop", pal: "cream, warm sand, amber gold, soft tan, and near-black ink",
    subj: "A lone figure seated at a luminous retrofuturist desktop workstation inside a vast calm sunlit hall, monumental floating browser windows and glowing app panels arranged around them like architecture, building software in a serene workspace, warm golden light pouring in, small human figure dwarfed by gentle monumental forms." },
  { name: "hero-cloud", pal: "cream, pale sky blue, deep cobalt, soft azure, and near-black ink",
    subj: "A small figure standing on a high terrace releasing a softly glowing application orb up into an immense luminous cloudscape, distant floating server-cities and structures on the bright horizon under a vast open sky, a calm sense of going live to the whole world." },
];
async function gen(prompt, out) {
  for (let a=1;a<=4;a++){
    const r = await fetch("https://openrouter.ai/api/v1/chat/completions",
      { method:"POST", headers:{ "Authorization":"Bearer "+KEY, "Content-Type":"application/json" },
        body: JSON.stringify({ model:"google/gemini-3-pro-image-preview", messages:[{role:"user",content:prompt}], modalities:["image","text"] }) });
    if (r.ok){ const d=await r.json();
      const imgs = d.choices?.[0]?.message?.images;
      if (imgs && imgs[0]){ const url=imgs[0].image_url.url; writeFileSync(out, Buffer.from(url.split(",",2)[1],"base64")); return true; }
      console.error("no image in resp:", JSON.stringify(d).slice(0,200)); }
    else if (r.status===429||r.status>=500){ await new Promise(s=>setTimeout(s,a*12000)); }
    else { console.error(r.status,(await r.text()).slice(0,200)); return false; }
  }
  return false;
}
for (const j of JOBS){
  process.stdout.write(j.name+" … ");
  console.log(await gen(`${j.subj}. Limited palette of ${j.pal}. ${CANON}`, `web/illos/${j.name}.png`) ? "ok" : "FAILED");
}
