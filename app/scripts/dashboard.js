import init, { Dashboard, call as simCall } from '../pkg/adbuy_sim.js';
import { readSave, writeSave } from '../save.js';
import { shake } from './ceremony.js';
import { unlockAudio, sfxTap, sfxDeal, sfxKill, sfxError, sfxTick } from './audio.js';
import { whisperTap, voiceDeal, voiceKill, voiceError } from './haptics.js';
import { funnelRow, diagnoseChip, cardLabel } from './cards.js';
import { runNight } from './night.js';
import { placeProposal, resetProposal } from './proposal.js';
import { runWeekClose, runNewsstand } from './week.js';
import { CONCEPTS } from './concepts.js';
import { syncGoalModal, wireGoal } from './goal.js';

/* ----- art: generated card art, in context. cycle the complete style sets ----- */
const STYLES = ["characters","sticker-pop","upa-flat","paper-cutout","cereal-mascot","midcentury-ad","storybook"];
let styleIdx = 0;
const SUBJECTS = ["combo","creator","product"];            // ad concept i -> subject image
const artUrl = i => `art/ads/${STYLES[styleIdx]}/${SUBJECTS[i % SUBJECTS.length]}.png`;

const VERTICALS = { cookware:"cookware brand", boots:"footwear brand" };
const CLIENTS   = { copper_char:"Copper & Char", tundra_boots:"Tundra Boots" };
const TRAITS    = { copper_char:["heritage","earnest","premium"], tundra_boots:["durable","adventurous","technical"] };

/* ----- save context (agency brand from onboarding) ----- */
let savedCtx = null;   // {brand:{name,...}, week, team, ...} — may be null for direct-load
let agencyName = null; // player's agency name, shown on sign screen

/* ----- WASM-driven state ----- */
let dash = null;      // Dashboard handle (owns the whole engagement)
let S = null;         // last parsed get_state() snapshot driving the desk
let seed = 0;
let myAds = [];       // [{concept, name, slots, art}] parallel to ads[] (1-based)
let belled = false;   // a Bell event fired this run -> pin CONFIRMED
let winnerIdx = 0;    // bell winner (0-based)
let busy = false;     // input lock during the night ceremony
let pinned = false, pinnedCall = 0;   // pinned: registered; pinnedCall: 1=A 2=B
let calledIdx = 0;    // 1-based ad index the player called as winner (0 = not called)
let prevAp = 0;       // AP value at last render, to detect refill
const skipRef = { value: false }; // mutable skip flag; recap tap sets true to skip night anim
const MAX_SLOTS = 3;

const $ = id => document.getElementById(id);
const dollars = cents => '$' + Math.round((cents||0)/100).toLocaleString();

function flash(msg, ms = 1600){
  const f = $('flash'); f.textContent = msg; f.classList.add('on');
  clearTimeout(f._t); f._t = setTimeout(()=>f.classList.remove('on'), ms);
}

try {
  await init();                                   // <-- the gate
  savedCtx = await readSave().catch(() => null);
  agencyName = savedCtx?.brand?.name || null;
  wireGoal();
  $('recap').addEventListener('click', () => { if (busy) skipRef.value = true; });
  newRun();
  syncSign();
  const pb = $('playbtn');
  pb.disabled = false;
  pb.textContent = 'Play';
  pb.onclick = () => { unlockAudio(); go('sign'); };
  if (new URLSearchParams(location.search).get('resume')) go('sign');
} catch (err) {
  console.error('[adbuy] WASM init failed:', err);
  $('booterr').textContent = String(err && err.message || err);
  $('boot').classList.add('on');
}

function go(id){
  document.querySelectorAll('.screen').forEach(s=>s.classList.remove('on'));
  $(id).classList.add('on');
}
// Unlock AudioContext on first pointer interaction (iOS gate).
document.addEventListener('pointerdown', unlockAudio, { once: true });
document.addEventListener('keydown', e => {
  if (busy) return;
  if (e.key === 'n' && $('endbtn') && !$('endbtn').disabled) nextDay();
  else if (e.key === 'b' && S && (S.state==='BUILD'||S.state==='FLIGHT') && (S.ap|0)>=1 && myAds.length<MAX_SLOTS) buildAd();
  else if (e.key === 'p' && S && S.state==='BUILD' && myAds.length>=2 && !pinned) window.__pin();
  else if (e.key === 'Escape') { $('goalmodal').classList.remove('on'); $('pmodal').classList.remove('on'); }
});

function newRun(){
  seed = (Math.floor(Math.random() * 0xffffffff)) >>> 0;
  dash = new Dashboard(seed);                     // constructor: start_run + ack_brief -> BUILD
  refresh();
  myAds = []; belled = false; winnerIdx = 0; busy = false; pinned = false; pinnedCall = 0; calledIdx = 0; diagCache = {}; resetProposal();
}
function refresh(){ S = JSON.parse(dash.get_state()); }

function syncSign(){
  $('brandname').textContent = CLIENTS[S.client] || S.client || '—';
  const vmap = S.client === 'tundra_boots' ? 'boots' : 'cookware';
  $('brandvert').textContent = VERTICALS[vmap];
  $('brandtraits').innerHTML =
    (TRAITS[S.client] || ['earnest','premium']).map(x=>`<span class="trait">${x}</span>`).join('');
  const bankAmt = S.bankroll > 0 ? S.bankroll : (savedCtx?.bankroll || 0);
  const bankLine = bankAmt > 0 ? `<div><span>Bankroll</span><b>${dollars(bankAmt)}</b></div>` : '';
  const wavesWon = S.global_wave > 1 ? S.global_wave - 1 : Math.max(0, (savedCtx?.week || 1) - 1);
  const runLine = wavesWon > 0 ? `<div><span>Run total</span><b>${wavesWon} wave${wavesWon!==1?'s':''} won</b></div>` : '';
  const bossLine = S.is_boss ? `<div><span>Miss it</span><b style="color:var(--red)">FIRED — no second chance</b></div>` : '';
  const trust = S.trust != null ? S.trust : 3;
  const trustPips = [1,2,3].map(i => `<span class="pip ${i <= trust ? '' : 'spent'}"></span>`).join('');
  const trustLine = (S.wave_in_client||1) >= 2
    ? `<div><span>Trust</span><b>${trustPips}</b></div>` : '';
  const floorLine = S.spend_floor > 0
    ? `<div><span>Spend at least</span><b>${dollars(S.spend_floor)}</b></div>` : '';
  $('brandladder').innerHTML =
    `<div><span>Job</span><b>${S.is_boss ? 'FINAL · Wave 3 of 3' : `Wave ${S.wave_in_client||1} of 3`}</b></div>` +
    `<div><span>Target</span><b>${dollars(S.target)} revenue</b></div>` +
    `<div><span>Fee if you pass</span><b>+${dollars(S.fee)}</b></div>` +
    floorLine + bossLine + trustLine + bankLine + runLine;
  const wn = S.wave_in_client || 1;
  const isNew = wn === 1;
  $('signheader').textContent = isNew ? 'They need a strategist.'
    : S.is_boss ? 'Wave 3 — the final.'
    : `Wave ${wn} begins.`;
  const hasStrategist = savedCtx?.team?.some(h => h.role === 'Creative Strategist' && h.id);
  $('signbody').textContent = isNew
    ? 'Three moves a day — build two ads to launch, then the market answers overnight.'
    : S.is_boss ? "Miss this and you're fired. No second chances — everything rides on this wave."
    : hasStrategist
      ? 'Harder target. Check your strategist\'s instinct before you build — predict the winner early, call it while they run.'
      : 'Harder target. Build two ads, predict the winner before you launch, then call it while they run.';
  $('signbtn').textContent = isNew ? 'Take the job' : (S.is_boss ? 'Begin final wave' : `Begin wave ${wn}`);
  const hireEl = $('signhire');
  if (hireEl) hireEl.innerHTML = (!isNew && !hasStrategist && !S.is_boss)
    ? '<a href="team-designer.html" class="signhire-link"><i class="ph-fill ph-users"></i> Hire a Creative Strategist first</a>'
    : '';
  $('rerollbtn').style.display = isNew ? '' : 'none';
  $('brandlogo').className = S.client === 'tundra_boots' ? 'ph-fill ph-boot' : 'ph-fill ph-cooking-pot';
  const aEl = $('agencyname');
  if (aEl) aEl.textContent = agencyName ? agencyName : '';
}
function reroll(){ sfxTap(); whisperTap(); newRun(); syncSign(); }
function enterDesk(){
  sfxTap(); whisperTap(); render(); go('desk');
  if (!localStorage.getItem('wbab_desk_hint_shown') && S && (S.wave_in_client||1) === 1 && !(S.ads && S.ads.length)){
    localStorage.setItem('wbab_desk_hint_shown', '1');
    setTimeout(() => { flash('Tap BUILD to create your first ad →', 2800); shake($('adrow')); }, 500);
  }
}

function buildAd(){
  if (busy) return;
  if (myAds.length >= MAX_SLOTS) return;
  if (S.state !== 'BUILD' && S.state !== 'FLIGHT'){
    flash('the week is closed'); shake($('adrow')); sfxError(); voiceError(); return;
  }
  if ((S.ap|0) < 1){
    flash('out of moves — end the day to refill'); shake($('adrow')); sfxError(); voiceError(); return;
  }
  const ci = myAds.length;
  const c = CONCEPTS[((((S.wave_in_client||1) - 1) * 3) + ci) % CONCEPTS.length];
  const clean = ci < 2;                            // first two ads form the clean A/B race
  const res = JSON.parse(dash.build_ad(c.cards, clean));
  if (!res.ok){ flash('build failed — try again'); shake($('adrow')); sfxError(); voiceError(); refresh(); render(); return; }
  sfxDeal(); voiceDeal();
  myAds.push({ concept:ci, name:c.name, slots:c.slots, art:ci });
  refresh(); render();
  if (myAds.length === 1 && !localStorage.getItem('wbab_est_hint_shown')) {
    localStorage.setItem('wbab_est_hint_shown', '1');
    setTimeout(() => flash('These are predicted rates — once live, real data replaces them', 2400), 600);
  }
  if (myAds.length === 2 && !localStorage.getItem('wbab_pin_hint_shown')) {
    localStorage.setItem('wbab_pin_hint_shown', '1');
    setTimeout(() => flash('Which ad wins? Predict it in the third slot before you launch →', 2800), 400);
  }
}

function killAd(i, ev){
  ev.stopPropagation();
  if (busy) return;
  if (S.state !== 'FLIGHT'){ flash('can only stop an ad while the week is running'); sfxError(); voiceError(); return; }
  const card = document.getElementById(`ad${i}`);
  if (!card || !card.dataset.killpending) {
    if (card) {
      card.dataset.killpending = '1';
      setTimeout(() => { if (card) delete card.dataset.killpending; }, 2000);
    }
    flash('Tap ✕ again to stop this ad →', 2000); sfxTap(); return;
  }
  delete card.dataset.killpending;
  const res = JSON.parse(dash.kill_ad(i + 1));     // 1-based
  if (!res.ok){ flash('could not stop ad'); sfxError(); voiceError(); }
  else { sfxKill(); voiceKill(); }
  refresh(); render();
}

function adLive(i){ return (S.ads && S.ads[i]) ? S.ads[i] : null; }

function render(){
  if (!S) return;
  const total = S.total_days || 5;
  const todayIdx = Math.min(S.day, total - 1);     // BUILD: day 0 -> planning day 1
  let html = '';
  for (let d = 0; d < total; d++){
    const isGoal = d === total - 1;
    const isToday = d === todayIdx && S.state !== 'NEWSSTAND';
    const done = d < todayIdx;
    const cls = isGoal ? 'goalday' : (isToday ? 'today' : (done ? 'done' : ''));
    const WD_SHORT = ['MON','TUE','WED','THU','FRI'];
    const label = isGoal ? 'GOAL' : (WD_SHORT[d] || 'Day');
    html += `<div class="wd ${cls}" ${isGoal?'onclick="openGoal()"':''}>${label}<small>${d+1}</small></div>`;
    if (d === todayIdx && !isGoal) html += `<span class="dwsep">${total - todayIdx - 1}d →</span>`;
  }
  $('daywin').innerHTML = html;
  const daysToGoal = Math.max(0, total - todayIdx - 1);
  $('goaldays').textContent = S.state === 'BUILD'
    ? (myAds.length >= 2 ? 'launch the week →' : 'build ads to launch')
    : daysToGoal === 0 ? 'GOAL DAY' : `${daysToGoal}d to goal`;

  const clientShort = { copper_char:'C&C', tundra_boots:'TB' };
  const wbEl = $('wavebadge');
  if (S.is_boss) {
    wbEl.textContent = `FINAL · ${clientShort[S.client]||S.client}`;
    wbEl.className = 'wavebadge boss';
  } else {
    wbEl.textContent = `Wave ${S.wave_in_client||1} · ${clientShort[S.client]||S.client}`;
    wbEl.className = 'wavebadge';
  }

  const apMax = (S.ap_per_day && S.ap_per_day !== null) ? S.ap_per_day : 3;
  const ap = S.ap == null ? apMax : S.ap;
  $('ap').innerHTML = Array.from({length:apMax}, (_,i)=>
    `<div class="apdot ${i >= ap ? 'spent':''}"></div>`).join('');
  if (ap > prevAp) {
    const dots = $('ap').children;
    for (let i = prevAp; i < ap && i < dots.length; i++){
      const d = dots[i]; const delay = (i - prevAp) * 70;
      setTimeout(() => {
        d.classList.add('refill'); sfxTick();
        setTimeout(() => d.classList.remove('refill'), 450);
      }, delay);
    }
  }
  prevAp = ap;

  $('bank').textContent = dollars(S.bankroll);
  $('brev').textContent = dollars(S.revenue);
  $('goalof').textContent = '/ ' + dollars(S.target);
  const fillPct = Math.min(100, (S.race_ppm||0) / 10000);
  $('revfill').style.width = fillPct + '%';
  if (S.state === 'FLIGHT' && S.day > 0 && S.target > 0) {
    const dLeft = Math.max(0, (S.total_days||5) - S.day - 1);
    const proj = S.revenue + (S.revenue / S.day) * dLeft;
    $('revfill').className = proj >= S.target ? 'pace-ok' : proj >= S.target * 0.7 ? 'pace-warn' : 'pace-bad';
  } else {
    $('revfill').className = '';
  }
  const roasVal = (S.ads && S.ads.length) ? roasOf(S.ads.reduce((a,x)=>({rev:a.rev+x.rev,sp:a.sp+x.spend}),{rev:0,sp:0})) : null;
  $('roas').textContent = roasVal !== null ? roasVal.toFixed(2) + '×' : '—';
  $('roas').className = 'roasv ' + (roasVal===null?'':roasVal>=2?'roas-good':roasVal>=1?'roas-ok':'roas-bad');
  const totalSpend = (S.ads||[]).reduce((s,a)=>s+a.spend,0);
  const sp = $('spendpill');
  if (S.state==='FLIGHT' && S.spend_floor>0){
    sp.style.display=''; $('spentval').textContent=`${dollars(totalSpend)} / ${dollars(S.spend_floor)}`; sp.className='hpill '+(totalSpend>=S.spend_floor?'floor-ok':totalSpend>=S.spend_floor*.7?'floor-warn':'floor-bad');
    if (!localStorage.getItem('wbab_floor_hint_shown')){ localStorage.setItem('wbab_floor_hint_shown','1'); setTimeout(()=>flash(`Spend at least ${dollars(S.spend_floor)} across your ads to qualify — keep them running all week`,2800),400); }
  } else sp.style.display='none';
  $('trust').innerHTML = Array.from({length:3}, (_,i)=>
    `<span class="pip ${i >= (S.trust||0) ? 'spent':''}"></span>`).join('');

  const a = adLive(0), b = adLive(1);
  if (S.state === 'FLIGHT' && a && b){
    $('raceplate').style.display = '';
    const tot = a.rev + b.rev;
    const lead = tot > 0 ? (a.rev - b.rev) / tot : 0;          // -1..1, +ve = A ahead
    $('needle').style.left = (50 + lead * 42) + '%';
    $('racen').textContent = ((a.imps + b.imps)).toLocaleString() + ' views';
  } else {
    $('raceplate').style.display = 'none';
  }

  const row = $('adrow');
  row.innerHTML = myAds.map((m,i)=>{
    const live = adLive(i);
    const rev = live ? live.rev : 0;
    const killed = live ? live.killed : false;
    const flying = S.state === 'FLIGHT' && !killed;
    const ftg = S.builds?.[i]?.fatigue||'FRESH', tw = ftg!=='FRESH'?`<span class="chip ch-tired"><i class="ph-fill ph-warning"></i>${ftg==='CREATIVE FATIGUE'?'FATIGUED':'WORN'}</span>`:'';
    const called = calledIdx === i+1 ? '<span class="chip ch-called"><i class="ph-fill ph-megaphone"></i>Called</span>' : '';
    let chip;
    if (killed) chip = '<span class="chip ch-killed"><i class="ph-fill ph-x-circle"></i>Stopped</span>';
    else if (S.state === 'BUILD') chip = '<span class="chip ch-learning"><i class="ph-fill ph-hourglass-medium"></i>Queued</span>';
    else if (S.day <= 1) chip = '<span class="chip ch-learning"><i class="ph-fill ph-hourglass-medium"></i>Warming up</span>';
    else if (i === winnerIdx && belled) chip = '<span class="chip ch-leader"><i class="ph-fill ph-crown"></i>Leader</span>';
    else chip = '<span class="chip ch-live"><i class="ph-fill ph-chart-line-up"></i>Live</span>';
    return `
    <div class="adcard ${killed?'killed':''} ${flying?'live':''} ${ftg!=='FRESH'?'tired':''}" id="ad${i}">
      <div class="killx" onclick="window.__kill(${i},event)">✕</div>
      <div class="art" style="background-image:url('${artUrl(m.art)}')">
        <div class="statusrow">
          ${i<2?`<span class="abtag">${'AB'[i]}</span>`:''}
          ${chip}${tw}${called}
        </div>
      </div>
      <div class="slots">${m.slots.map(s=>`<div class="ms">${s}</div>`).join('')}</div>
      <div class="meta">
        <h4>${m.name}</h4>
        <div class="rev">${dollars(rev)}</div>
        ${flying && live ? `<div class="adspend">${dollars(live.spend)} spent${live.roas_x1000 > 0 ? ` · <span class="ad-roas ${live.roas_x1000>=2000?'roas-good':live.roas_x1000>=1000?'roas-ok':'roas-bad'}">return ${(live.roas_x1000/1000).toFixed(2)}×</span>` : ''}</div>` : ''}
      </div>
      ${funnelRow(S, i)}
      ${diagnoseChip(S, diagCache, i, live)}
    </div>`;
  }).join('') + emptySlots();

  // END DAY gating: BUILD needs >=2 ads (the $600 spend floor on $400 builds)
  const endbtn = $('endbtn');
  if (S.state === 'BUILD'){
    const enough = myAds.length >= 2;
    endbtn.disabled = busy;
    endbtn.firstChild.textContent = enough ? 'LAUNCH WEEK ' : myAds.length === 0 ? 'BUILD FIRST AD ' : 'BUILD ONE MORE ';
  } else if (S.state === 'FLIGHT'){
    endbtn.disabled = busy;
    const onGoalDay = S.day >= (S.total_days||5) - 1;
    endbtn.firstChild.textContent = onGoalDay ? 'END WEEK ' : 'END DAY ';
  } else {
    endbtn.disabled = true;
    endbtn.firstChild.textContent = 'WEEK DONE ';
  }
  const shouldPrompt = !busy && !endbtn.disabled && (
    (S.state === 'BUILD' && myAds.length >= 2) ||
    (S.state === 'FLIGHT' && ((S.ap|0) === 0 || calledIdx > 0 || S.day >= 2))
  );
  endbtn.classList.toggle('prompt', shouldPrompt);
  if (shouldPrompt && S.state === 'FLIGHT' && !localStorage.getItem('wbab_endday_hint_shown')) {
    localStorage.setItem('wbab_endday_hint_shown', '1');
    setTimeout(() => flash('Tap END DAY — your ads run overnight and revenue lands at dawn', 2800), 700);
  }

  syncGoalModal(S, CLIENTS, dollars);
  placeProposal(S, busy);
  if (!localStorage.getItem('wbab_brain_nudge_shown') && document.querySelector('.pbadge:not(.read)')){
    localStorage.setItem('wbab_brain_nudge_shown', '1');
    setTimeout(() => flash('Your strategist has a suggestion — tap the brain →', 3200), 600);
  }
  if (!localStorage.getItem('wbab_diagnose_hint_shown') && document.querySelector('.dx-btn:not(.dx-warm):not(.dx-done)')){
    localStorage.setItem('wbab_diagnose_hint_shown', '1');
    setTimeout(() => flash('Tap DIAGNOSE to see why your ad converts →', 2800), 500);
  }
}

function roasOf({rev,sp}){ return sp > 0 ? rev/sp : null; }

let diagCache = {};
window.__diagnose = (i) => { if(busy)return; const r=JSON.parse(dash.diagnose_ad(i+1)); diagCache[i]=r.diagnosable?r:false; sfxTap();whisperTap();render(); };
window.__pin = (call) => { if(busy||pinned)return; JSON.parse(dash.pin_ab("HOOK", call)); pinned=true; pinnedCall=call; sfxTap();whisperTap();render(); };

function emptySlots(){
  let html = '';
  const canBuild = !busy && (S.state === 'BUILD' || S.state === 'FLIGHT') && (S.ap|0) >= 1 && myAds.length < MAX_SLOTS;
  for (let k = myAds.length; k < MAX_SLOTS; k++){
    // CALL LOCKED / CALL IT: take priority over buildable in FLIGHT once day ≥ 2
    if (k === 2 && S.state === 'FLIGHT' && myAds.length >= 2 && calledIdx){
      const callLabel = 'AB'[calledIdx - 1] || 'A';
      html += `<div class="emptyslot pin-slot pin-locked"><i class="ph-fill ph-megaphone" style="color:var(--blue);font-size:18px"></i>CALL LOCKED<small style="color:var(--dim);font-size:9px">${callLabel} called to win</small><div class="pin-confirm"><i class="ph-fill ph-check-circle" style="color:var(--green);font-size:16px"></i></div></div>`;
    } else if (k === 2 && S.state === 'FLIGHT' && myAds.length >= 2 && !calledIdx && S.day >= 2){
      html += `<div class="emptyslot pin-slot"><i class="ph-fill ph-megaphone" style="color:var(--blue);font-size:18px"></i>CALL IT<small style="color:var(--dim);font-size:9px">lock in the winner</small><div class="call-ab"><button onclick="window.__callit(0)">A wins</button><button onclick="window.__callit(1)">B wins</button></div></div>`;
    } else if (k === myAds.length && canBuild){
      const nextCi = myAds.length;
      const previewC = CONCEPTS[((((S.wave_in_client||1) - 1) * 3) + nextCi) % CONCEPTS.length];
      const cardChips = previewC.cards.split(',').map(id=>`<span class="concept-card">${cardLabel(id)}</span>`).join('');
      html += `<div class="emptyslot buildable" onclick="window.__build()">
        <div class="concept-cards">${cardChips}</div>
        <div class="concept-name">${previewC.name}</div>
        <small>1 move · $400 budget</small>
        <div class="build-cta">BUILD <i class="ph-bold ph-arrow-right"></i></div></div>`;
    } else if (k === 2 && S.state === 'BUILD' && myAds.length >= 2 && pinned){
      const pinLabel = 'AB'[pinnedCall - 1] || 'A';
      html += `<div class="emptyslot pin-slot pin-locked"><i class="ph-fill ph-push-pin" style="color:var(--blue);font-size:18px"></i>PIN LOCKED<small style="color:var(--dim);font-size:9px">${pinLabel} predicted to win</small><div class="pin-confirm"><i class="ph-fill ph-check-circle" style="color:var(--green);font-size:16px"></i></div></div>`;
    } else if (k === 2 && S.state === 'BUILD' && myAds.length >= 2 && !pinned){
      html += `<div class="emptyslot pin-slot"><i class="ph-fill ph-push-pin" style="color:var(--blue);font-size:18px"></i>PIN IT<small style="color:var(--dim);font-size:9px">predict the winner</small><div class="call-ab"><button onclick="window.__pin(1)">A wins</button><button onclick="window.__pin(2)">B wins</button></div></div>`;
    } else {
      const why = myAds.length >= MAX_SLOTS ? 'slots full'
                : (S.ap|0) < 1 ? 'needs a move'
                : (S.state !== 'BUILD' && S.state !== 'FLIGHT') ? 'week closed' : 'ad slot';
      html += `<div class="emptyslot passive">
        <i class="ph-fill ph-cards slotmark"></i>AD SLOT<small>${why}</small></div>`;
    }
  }
  return html;
}

function nextDay(){
  if (busy) return;
  if (S.state === 'BUILD' && myAds.length < 2){
    flash(myAds.length === 0 ? 'tap the BUILD slot to create your first ad →' : 'build one more ad to launch →');
    shake($('adrow')); return;
  }
  if (S.state !== 'BUILD' && S.state !== 'FLIGHT') return;
  sfxTap(); whisperTap();
  busy = true;
  $('endbtn').disabled = true;

  const prev = {};
  (S.ads||[]).forEach((ad,i)=>{ prev[i] = { rev:ad.rev, spend:ad.spend }; });

  const out = JSON.parse(dash.end_day());
  if (!out.ok){ busy = false; refresh(); render(); flash(out.msg || 'cannot advance'); return; }

  const after = out.state;                          // end_day() embeds state as a nested object
  const events = out.events || [];
  const autopsy = events.find(e => e.type === 'autopsy');
  const bell = events.find(e => e.type === 'bell');
  if (bell){ belled = true; winnerIdx = (bell.winner|0) - 1; }

  while (myAds.length < (after.ads ? after.ads.length : 0)){
    const ci = myAds.length; const c = CONCEPTS[ci % CONCEPTS.length];
    myAds.push({ concept:ci, name:c.name, slots:c.slots, art:ci });
  }

  if (!localStorage.getItem('wbab_skip_hint_shown')) {
    setTimeout(() => {
      if (!skipRef.value && busy) {
        flash('tap the screen to skip →', 2200);
        localStorage.setItem('wbab_skip_hint_shown', '1');
      }
    }, 1500);
  }
  runNight(after, prev, bell, autopsy, {
    myAds, pinned, winnerIdx, artUrl, skip: skipRef,
    onDone: finalState => {
      S = finalState; busy = false;
      $('endbtn').disabled = false;
      render();
      if (S.state === 'FLIGHT' && S.day === 1 && myAds.length < MAX_SLOTS && !localStorage.getItem('wbab_flight_hint_shown')){
        localStorage.setItem('wbab_flight_hint_shown', '1');
        setTimeout(() => flash('Ads are live — you can still build while they run →', 3200), 400);
      }
      if (S.state === 'FLIGHT' && S.day === 2 && !localStorage.getItem('wbab_call_nudge_shown')){
        localStorage.setItem('wbab_call_nudge_shown', '1');
        setTimeout(() => flash('Day 2 — call your winner when you\'re ready →', 3200), 400);
      }
      const daysLeft = (S.total_days||5) - (S.day||0) - 1;
      if (S.state === 'FLIGHT' && daysLeft === 0 && !localStorage.getItem('wbab_goalday_hint_shown')){
        localStorage.setItem('wbab_goalday_hint_shown', '1');
        setTimeout(() => flash('Goal day — make your last moves count →', 3200), 400);
      }
      if (S.state === 'FLIGHT' && (S.day||0) >= 3 && !calledIdx && !belled && !localStorage.getItem('wbab_call_late_hint_shown')){
        localStorage.setItem('wbab_call_late_hint_shown', '1');
        setTimeout(() => flash('Who\'s winning? Call it in slot 3 →', 2800), 700);
      }
    },
    onClose: () => { S = after; busy = false; weekClose(); },
  });
}


function weekClose(){
  refresh();
  // Persist wave count so Continue on home screen reflects progress.
  if (savedCtx && (S.state === 'NEWSSTAND' || S.state === 'RUN_WON' || S.state === 'FIRED')) {
    writeSave({ ...savedCtx, week: Math.max(savedCtx.week||1, (S.global_wave||1) + 1), bankroll: S.bankroll || 0 })
      .catch(() => {});
  }
  // Auto-diagnose undiagnosed ads with enough impressions — so close screen can show why they missed.
  if (S.ads) {
    S.ads.forEach((ad, i) => {
      if (diagCache[i] === undefined && ad.imps >= 2000) {
        try { const r = JSON.parse(dash.diagnose_ad(i+1)); diagCache[i] = r.diagnosable ? r : false; } catch(e) {}
      }
    });
  }
  runWeekClose(S, {
    belled, winnerIdx, pinned, pinnedCall, calledIdx, diagCache, dollars, go,
    onRunBack: () => { sfxTap(); whisperTap(); newRun(); syncSign(); go('sign'); },
    onNextBrief: (S.last_pack && S.last_pack.length) ? goNewsstand : nextBrief,
  });
}

function goNewsstand(){
  sfxTap(); whisperTap();
  runNewsstand(S, { dollars, go, onNext: nextBrief });
}
function nextBrief(){
  sfxTap(); whisperTap();
  const prevClient = S.client;
  S = JSON.parse(dash.next_wave());                // leave newsstand -> ack next brief -> BUILD
  myAds = []; belled = false; winnerIdx = 0; busy = false; pinned = false; pinnedCall = 0; calledIdx = 0; diagCache = {}; resetProposal();
  refresh();
  syncSign();
  go('sign');
}

window.cycleStyle = () => {
  styleIdx = (styleIdx + 1) % STYLES.length;
  $('stylename').textContent = STYLES[styleIdx];
  if (S) render();
};
window.reroll = reroll;
window.enterDesk = enterDesk;
window.nextDay = nextDay;
window.__build = buildAd;
window.__kill = killAd;
window.__callit = i => { if(busy||calledIdx)return; JSON.parse(dash.call_it(i+1)); calledIdx=i+1; sfxTap();whisperTap();render(); };
window.__estHint = () => flash('Predicted rates based on your card combo — once live, real data replaces them', 2400);
