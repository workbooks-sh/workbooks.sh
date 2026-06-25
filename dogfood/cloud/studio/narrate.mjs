#!/usr/bin/env node
// narrate.mjs — synthesize the Studio editorial into a single narrated MP3 via ElevenLabs.
// Key is read from XI_API_KEY (passed inline at runtime; NEVER committed). Voice/model overridable.
//   XI_API_KEY=... node narrate.mjs
// Writes public/editorial.mp3 (served by Vite at /editorial.mp3).

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const DIR = path.dirname(fileURLToPath(import.meta.url))
const KEY = process.env.XI_API_KEY
const VOICE = process.env.XI_VOICE || 'q0IMILNRPxOgtBTS4taI' // library narrator
const MODEL = process.env.XI_MODEL || 'eleven_v3'
if (!KEY) { console.error('XI_API_KEY not set'); process.exit(1) }

// markdown → speakable prose: drop headings markers, emphasis, links, rules; keep sentences.
function speakable(md) {
  return md
    .replace(/```[\s\S]*?```/g, '')           // code blocks
    .replace(/^\s*#{1,6}\s*/gm, '')           // heading hashes
    .replace(/^\s*[-*]\s+/gm, '')             // bullet markers
    .replace(/\*\*([^*]+)\*\*/g, '$1')        // bold
    .replace(/\*([^*]+)\*/g, '$1')            // italic
    .replace(/`([^`]+)`/g, '$1')              // inline code
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')  // links
    .replace(/^\s*[-—]{3,}\s*$/gm, '')        // hr
    .replace(/\n{3,}/g, '\n\n')
    .trim()
}

// chunk paragraphs into <~3500-char segments (API cap is 5000) on paragraph boundaries
function chunk(text, max = 3500) {
  const paras = text.split(/\n\n+/)
  const out = []
  let cur = ''
  for (const p of paras) {
    if ((cur + '\n\n' + p).length > max && cur) { out.push(cur.trim()); cur = p }
    else cur = cur ? cur + '\n\n' + p : p
  }
  if (cur.trim()) out.push(cur.trim())
  return out
}

const md = fs.readFileSync(path.join(DIR, 'src/lib/editorial.md'), 'utf8')
const segs = chunk(speakable(md))
console.error(`narrating ${segs.length} segments → /editorial.mp3 (voice ${VOICE}, ${MODEL})`)

const buffers = []
for (let i = 0; i < segs.length; i++) {
  const res = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${VOICE}?output_format=mp3_44100_128`, {
    method: 'POST',
    headers: { 'xi-api-key': KEY, 'content-type': 'application/json' },
    body: JSON.stringify({
      model_id: MODEL, text: segs[i],
      voice_settings: { stability: 0.4, similarity_boost: 0.75, style: 0.15 }
    })
  })
  if (!res.ok) { console.error(`ElevenLabs ${res.status} on seg ${i}: ${await res.text()}`); process.exit(1) }
  buffers.push(Buffer.from(await res.arrayBuffer()))
  console.error(`  seg ${i + 1}/${segs.length} ok (${segs[i].length} chars)`)
}

const buf = Buffer.concat(buffers)
const out = path.join(DIR, 'public/editorial.mp3')
fs.writeFileSync(out, buf)
console.error(`wrote ${out} (${(buf.length / 1024).toFixed(0)} KB, ${segs.length} segments)`)
