// Card-level render helpers — consumed by dashboard.js
const LABELS = { hook_pain:'Problem Hook', hook_founder:'Founder Story', hook_stat:'Stat Shock', hook_fomo:'FOMO Drop', hook_question:'Question Opener', hook_social:'Social Proof', vis_ugc:'Selfie Clip', vis_demo:'Demo Closeup', vis_before:'Before/After', vis_cine:'Cinematic Pour', vis_testimonial:'Testimonial', vis_result:'Result Reveal', fmt_video:'Short Video', fmt_carousel:'Carousel', fmt_story:'Stories', off_bundle:'Bundle & Save', off_trial:'Free Trial', off_discount:'Flash Discount' };
export const cardLabel = id => LABELS[id] || id.replace(/_/g,' ');
export const cardCategory = id =>
  id.startsWith('hook_') ? 'Opener' : id.startsWith('vis_') ? 'Visual' :
  id.startsWith('fmt_') ? 'Format' : id.startsWith('off_') ? 'Offer' : 'Card';

export function funnelRow(S, i){
  const p1 = v => (v/10000).toFixed(1)+'%', p2 = v => (v/10000).toFixed(2)+'%';
  const row = (cls,h,c,v,lbl='') => `<div class="fnl-row ${cls}">${lbl}<span>stop <b>${h}</b></span><span>click <b>${c}</b></span><span>buy <b>${v}</b></span></div>`;
  if (S.state==='BUILD'){ const b=S.builds&&S.builds[i]; if(!b)return ''; const ctr=Math.round(b.hook_ppm/1000*b.click_ppm/1000); return row('proj',p1(b.hook_ppm),p2(ctr),p2(b.cvr_ppm),'<span class="fnl-proj-lbl" onclick="window.__estHint&&window.__estHint()">est.</span>'); }
  if (S.state==='FLIGHT'){ const a=S.ads&&S.ads[i]; if(!a||a.imps<200)return ''; return row('live',p1(a.hook_ppm),p2(a.ctr_ppm),p2(a.cvr_ppm)); }
  return '';
}

export function diagnoseChip(S, diagCache, i, live){
  if (S.state!=='FLIGHT'||!live||live.killed) return '';
  if (live.imps < 500) return '';
  if (live.imps < 2000) return `<div class="dx-btn dx-warm"><i class="ph-fill ph-timer"></i>gathering data — ${(2000-live.imps).toLocaleString()} more views</div>`;
  const v = diagCache[i];
  if (v===undefined) return `<div class="dx-btn" onclick="window.__diagnose(${i})"><i class="ph-fill ph-stethoscope"></i>DIAGNOSE</div>`;
  if (!v) return `<div class="dx-btn dx-done"><i class="ph-fill ph-check-circle"></i>Healthy</div>`;
  const CHIP_LBL = { HOOK:'STOP', CTR:'CLICK', CVR:'BUY' };
  const chipLbl = CHIP_LBL[v.chip] || v.chip;
  return `<div class="dx-verdict dx-${v.chip.toLowerCase()}" onclick="window.__diagnose(${i})"><b>${chipLbl}</b> — ${v.sentence}</div>`;
}
