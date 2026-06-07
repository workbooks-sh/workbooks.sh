// CLIP sidecar — image+text into ONE space (cross-modal), behind the Embed.Http
// contract: POST /embed {inputs:[...],modality:"text"|"image"} -> {vectors:[...]}.
// The cloud default image+text embedder. transformers.js (onnxruntime) — proven.
import http from 'node:http';
import { AutoTokenizer, CLIPTextModelWithProjection, AutoProcessor, CLIPVisionModelWithProjection, RawImage } from '@huggingface/transformers';
const MODEL = process.env.CLIP_MODEL || 'Xenova/clip-vit-base-patch32', dtype = 'q8';
process.stderr.write('loading CLIP…\n');
const tokenizer = await AutoTokenizer.from_pretrained(MODEL);
const textModel = await CLIPTextModelWithProjection.from_pretrained(MODEL, { dtype });
const processor = await AutoProcessor.from_pretrained(MODEL);
const visionModel = await CLIPVisionModelWithProjection.from_pretrained(MODEL, { dtype });
process.stderr.write('CLIP ready\n');
const l2 = a => { const n = Math.sqrt(a.reduce((s,x)=>s+x*x,0)); return n ? a.map(x=>x/n) : a; };
const rows = t => { const [n,d]=t.dims, out=[]; for(let i=0;i<n;i++) out.push(l2(Array.from(t.data.slice(i*d,(i+1)*d)))); return out; };
async function embedText(texts){ const {text_embeds} = await textModel(tokenizer(texts,{padding:true,truncation:true})); return rows(text_embeds); }
async function embedImage(srcs){ const out=[]; for(const s of srcs){ const img = s.startsWith('data:')||/^[A-Za-z0-9+/=]+$/.test(s.slice(0,40)) ? await RawImage.fromBlob(new Blob([Buffer.from(s.replace(/^data:[^,]+,/,''),'base64')])) : await RawImage.read(s); const {image_embeds} = await visionModel(await processor(img)); out.push(...rows(image_embeds)); } return out; }
http.createServer((req,res)=>{
  if(req.method!=='POST'){ res.writeHead(404); return res.end(); }
  let b=''; req.on('data',c=>b+=c); req.on('end', async()=>{
    try{ const {inputs,modality}=JSON.parse(b); const vectors = modality==='image' ? await embedImage(inputs) : await embedText(inputs);
      res.writeHead(200,{'content-type':'application/json'}); res.end(JSON.stringify({vectors})); }
    catch(e){ res.writeHead(500); res.end(JSON.stringify({error:String(e)})); }
  });
}).listen(process.env.CLIP_PORT||8723, ()=>process.stderr.write('CLIP sidecar on '+(process.env.CLIP_PORT||8723)+'\n'));
