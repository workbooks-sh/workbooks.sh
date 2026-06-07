import { call as simCall } from '../pkg/adbuy_sim.js';
import { sfxTap } from './audio.js';
import { whisperTap } from './haptics.js';

const $ = id => document.getElementById(id);
const DAY_STAGES = ["PROBLEM","PRODUCT","PRODUCT","CLAIM","PROOF"];
const METRIC_LABELS = { HOOK:'stop rate', CTR:'click rate', CVR:'buy rate' };
const ASPECT_LABELS = {
  problem:'Problem Awareness', solution:'Solution Appeal', mechanism:'How It Works',
  comparison:'Comparison', social_proof:'Social Proof', trust:'Trust',
  urgency:'Urgency', scarcity:'Scarcity', offer_strength:'Offer Strength', novelty:'Novelty',
};
const aspectLabel = a => ASPECT_LABELS[a] || a.replace(/_/g,' ').replace(/\b\w/g, c => c.toUpperCase());
const proposalCache = {};
let strategistHire = null;
let proposalRead = -1;

export async function loadStrategistFromSave(){
  const {readSave} = await import('../save.js');
  const s = await readSave();
  if(s && s.team){
    const t = s.team.find(h => h.role==='Creative Strategist' && h.id && h.skill_x1000);
    if(t) strategistHire = t;
  }
}
loadStrategistFromSave();

export function resetProposal(){ proposalRead = -1; Object.keys(proposalCache).forEach(k => delete proposalCache[k]); }

function getProposal(S, key){
  if(proposalCache[key]) return proposalCache[key];
  if(!S || !strategistHire) return null;
  const stage = DAY_STAGES[Math.min(key,4)] || "PRODUCT";
  const args = {seed:S.seed, stage, noted_aspects:[], count:1, hires:[{
    id: strategistHire.id,
    style: strategistHire.style || "analytical",
    skill_x1000: strategistHire.skill_x1000 || 600,
    confidence_bias_x1000: strategistHire.confidence_bias_x1000 || 1000,
  }]};
  try{
    const raw = simCall("strategist_propose", JSON.stringify(args));
    const arr = JSON.parse(raw);
    if(arr && arr.length > 0) proposalCache[key] = arr[0];
    return proposalCache[key] || null;
  }catch(e){ return null; }
}

function proposalText(p){
  const dir = p.direction===1 ? 'lifts' : 'hurts';
  const metric = METRIC_LABELS[p.metric] || p.metric.toLowerCase();
  return `<b>${aspectLabel(p.aspect)}</b> ${dir} <em>${metric}</em>. ${p.rationale}.`;
}

const STYLE_FACE = { analytical:'🧠', creative:'🎨', fastmover:'⚡', meticulous:'🔬' };

function openProposal(p, key){
  $('mbody').innerHTML = proposalText(p);
  $('mconf').textContent = 'says ' + Math.round(p.claimed_confidence_x1000/10) + '% sure';
  if (strategistHire) {
    $('mname').textContent = strategistHire.name || 'Strategist';
    const sk = strategistHire.skill_x1000 || 600;
    const stars = sk >= 900 ? '★★★★' : sk >= 750 ? '★★★' : sk >= 500 ? '★★' : '★';
    $('mrole').textContent = (strategistHire.role || 'Creative Strategist') + ' · ' + stars;
    $('mskill').textContent = Math.round(sk / 10) + '%';
    $('mface').textContent = STYLE_FACE[strategistHire.style] || '🧠';
  }
  $('pmodal').classList.add('on');
  proposalRead = key;
}

export function placeProposal(S, busy){
  document.querySelectorAll('.pbadge').forEach(b => b.remove());
  if(!S || busy) return;
  if(S.state !== 'BUILD' && S.state !== 'FLIGHT') return;
  const key = Math.min(S.day, 4);
  const p = getProposal(S, key);
  if(!p) return;
  let el = document.querySelector('.emptyslot:not(.passive)') || document.getElementById('raceplate') || document.getElementById('ad0');
  if(!el) return;
  el.style.position = 'relative';
  const b = document.createElement('div');
  b.className = 'pbadge' + (proposalRead === key ? ' read' : '');
  b.innerHTML = '<i class="ph-fill ph-brain"></i>';
  b.onclick = ev => { ev.stopPropagation(); openProposal(p, key); sfxTap(); whisperTap(); };
  el.appendChild(b);
}

window.closeProposal = ev => {
  if(ev && ev.target.closest && ev.target.closest('.mpanel')) return;
  $('pmodal').classList.remove('on');
};
