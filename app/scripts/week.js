// Post-week-end screens: close summary and newsstand pack reveal.
import { sfxWin, sfxMiss, sfxDeal } from './audio.js';
import { voiceSuccess, voiceFail } from './haptics.js';
import { cardLabel, cardCategory } from './cards.js';
import { conceptsFor, CONCEPTS } from './concepts.js';

function buildConceptName(cards) {
  const key = [...cards].sort().join(',');
  return (CONCEPTS.find(c => [...c.cards.split(',')].sort().join(',') === key) || {}).name || null;
}

const $ = id => document.getElementById(id);
const CLIENT_NAME = { copper_char: 'Copper & Char', tundra_boots: 'Tundra Boots' };
const clientName = c => CLIENT_NAME[c] || c;

export function runWeekClose(S, {
  belled, winnerIdx, pinned, pinnedCall, calledIdx, diagCache,
  dollars, go, onRunBack, onNextBrief,
}) {
  const lr = S.last_result;
  const passed = lr ? lr.passed : (S.revenue >= S.target);
  const rev = lr ? lr.revenue_cents : S.revenue;
  const sp  = lr ? lr.spend_cents   : 0;
  const fee = lr ? lr.payout_cents  : S.fee;

  $('verdict').textContent = passed ? 'WEEK PASSED' : 'WEEK MISSED';
  $('verdict').className = 'verdict disp ' + (passed ? 'pass' : 'miss');
  if (passed) { sfxWin(); voiceSuccess(); } else { sfxMiss(); voiceFail(); }

  const roas = sp > 0 ? (rev/sp).toFixed(2) + '×' : '—';
  const trustLeft = passed ? '' : (S.trust > 0 ? ` · ${S.trust} trust left` : '');
  const trust = S.trust != null ? S.trust : 0;
  const feelineEl = $('feeline');
  if (feelineEl) {
    if (passed) {
      const bankTotal = S.bankroll || 0;
      const bankLine = bankTotal > fee ? `<span class="fee-bank"> · bankroll ${dollars(bankTotal)}</span>` : '';
      feelineEl.innerHTML = `<span class="fee-earned">+${dollars(fee)}</span><span class="fee-label"> your fee</span>${bankLine}`;
    } else if (trust > 1) {
      feelineEl.innerHTML = `<span class="fee-miss">${trust} trust left — keep the client</span>`;
    } else if (trust === 1) {
      feelineEl.innerHTML = `<span class="fee-miss fee-last">last trust — don't miss again</span>`;
    } else {
      feelineEl.innerHTML = '';
    }
  }
  const roasNum = sp > 0 ? rev / sp : null;
  const roasCls = roasNum === null ? '' : roasNum >= 2 ? 'roas-good' : roasNum >= 1 ? 'roas-ok' : 'roas-bad';
  const roasHtml = roasNum !== null ? ` · return <b class="roasv ${roasCls}">${roas}</b>` : '';
  const missHtml = passed ? '' : ` · lost a trust${trustLeft}`;
  const diagHint = (!passed && diagCache) ? (() => {
    const hit = Object.entries(diagCache).find(([,v]) => v && v.sentence);
    if (!hit) return '';
    const [idx, v] = hit;
    return `<div class="close-diag"><b>${'AB'[+idx] || 'Ad'}</b> — ${v.sentence}</div>`;
  })() : '';
  $('closedetail').innerHTML = `${dollars(rev)} revenue of ${dollars(S.target)}${roasHtml}${missHtml}${diagHint}`;

  const learnEl = $('closelearn');
  if (learnEl) {
    let learn = '';
    if (passed && belled && S.ads && S.ads.length >= 2) {
      const wi = (winnerIdx != null ? winnerIdx : 0), li = wi === 0 ? 1 : 0;
      const wh = S.ads[wi] && S.ads[wi].hook_ppm, lh = S.ads[li] && S.ads[li].hook_ppm;
      if (wh > 0 && lh > 0) {
        const ratio = wh / Math.max(lh, 1);
        learn = `${'AB'[wi]} stopped ${(wh/10000).toFixed(1)}% — ${ratio.toFixed(1)}× Ad ${'AB'[li]}'s ${(lh/10000).toFixed(1)}%`;
      }
    } else if (!passed && S.target > 0 && rev > 0) {
      const gap = dollars(S.target - rev);
      learn = `${gap} short of target`;
    }
    learnEl.textContent = learn;
    learnEl.style.display = learn ? '' : 'none';
  }

  const callEl = $('callresult');
  if (S.call_idx > 0) {
    const cl = 'AB'[S.call_idx-1] || '?';
    const right = S.call_verdict === 'CONFIRMED';
    callEl.innerHTML = `<i class="ph-fill ph-megaphone" style="color:var(--blue)"></i><span>${cl} called as winner</span><span class="stamp2${right?'':' inc'}">${right ? 'CALLED IT' : 'WRONG CALL'}</span>`;
  } else { callEl.innerHTML = ''; }
  callEl.style.display = S.call_idx > 0 ? '' : 'none';

  const codexEl = $('codexcount');
  const codexTxt = [
    (S.codex&&(S.codex.canon+S.codex.observed)>0 ? `${S.codex.canon} test result${S.codex.canon!==1?'s':''} · ${S.codex.observed} insight${S.codex.observed!==1?'s':''}` : ''),
    (S.packs_opened ? `${S.packs_opened} pack${S.packs_opened>1?'s':''} opened` : ''),
    (S.collection_size ? `${S.collection_size} card${S.collection_size>1?'s':''} collected` : ''),
  ].filter(Boolean).join(' · ');
  codexEl.textContent = codexTxt;
  codexEl.style.display = codexTxt ? '' : 'none';

  const hasPack = S.last_pack && S.last_pack.length;
  const packEl = $('packrow');
  if (hasPack) {
    packEl.innerHTML = S.state === 'NEWSSTAND'
      ? `<span class="packrow-label"><i class="ph-fill ph-package"></i>PACK OPENING</span><span class="cardtag">${S.last_pack.length} card${S.last_pack.length!==1?'s':''}</span>`
      : `<span class="packrow-label"><i class="ph-fill ph-package"></i>NEW</span>${S.last_pack.map(id=>`<span class="cardtag">${cardLabel(id)}</span>`).join('')}`;
  } else {
    packEl.innerHTML = '';
  }
  packEl.style.display = hasPack ? '' : 'none';

  const wasBoss = lr && lr.is_boss;
  const winBuild = (belled && winnerIdx != null && S.builds) ? S.builds[winnerIdx] : null;
  const fatigueTag = winBuild ? (() => {
    const ftg = winBuild.fatigue || 'FRESH';
    if (ftg === 'FRESH') return '';
    const label = ftg === 'CREATIVE FATIGUE' ? 'fatigued' : 'worn';
    const cname = buildConceptName(winBuild.cards || []);
    return ` <span class="chip ch-tired" style="font-size:9px">${cname ? cname + ' ' : 'AB'[winnerIdx] + ' '}${label}</span>`;
  })() : '';
  const WAVE_MULTS = [1000, 1500, 2000];
  const nextWaveN = (S.wave_in_client||0) + 1;
  const curMult = WAVE_MULTS[(S.wave_in_client||1) - 1] || 1000;
  const nextMult = WAVE_MULTS[nextWaveN - 1];
  const nextTargetTag = (!wasBoss && nextMult && S.target > 0)
    ? ` <span class="nextup-target">${dollars(Math.round(S.target * nextMult / curMult))}</span>`
    : '';
  const nextCtaLabel = (!wasBoss && nextMult)
    ? `Wave ${nextWaveN} →`
    : 'Next wave →';
  $('nextup').innerHTML = (passed && !wasBoss)
    ? `<span class="nextup-label"><i class="ph-fill ph-arrow-right"></i>NEXT</span><span class="nextup-val">Wave ${nextWaveN} · ${clientName(S.client)}${fatigueTag}${nextTargetTag}</span>`
    : (passed && wasBoss)
    ? `<span class="nextup-label"><i class="ph-fill ph-arrow-right"></i>NEXT</span><span class="nextup-val">New client</span>`
    : '';

  const pv = lr && lr.pin_verdict && lr.pin_verdict !== 'NONE' ? lr.pin_verdict : (belled ? 'CONFIRMED' : null);
  const pm = lr && lr.pin_metric ? lr.pin_metric : 'HOOK';
  const PM_LABELS = { HOOK:'stop rate', CTR:'click rate', CVR:'buy rate' };
  const pmLabel = PM_LABELS[pm] || pm.toLowerCase();
  const showPin = pinned || belled;
  $('pinresult').style.display = showPin ? '' : 'none';
  if (showPin) {
    $('pinlabel').textContent = pinned
      ? `${'AB'[pinnedCall-1]||'A'} wins on ${pmLabel}`
      : `${'AB'[winnerIdx]||'A'} won its race`;
    const grade = $('pingrade');
    grade.textContent = pv || 'INCONCLUSIVE';
    grade.className = 'stamp2' + (pv === 'CONFIRMED' ? '' : ' inc');
  }

  const progEl = $('progressrow');
  if (S.state !== 'FIRED' && S.state !== 'RUN_WON') {
    const waveN = S.wave_in_client || 1;
    const waveDots = [1,2,3].map(i => `<span class="prog-dot${i <= waveN ? ' done' : ''}"></span>`).join('');
    const trust = S.trust != null ? S.trust : 3;
    const trustDots = [1,2,3].map(i => `<span class="prog-dot trust${i <= trust ? ' alive' : ''}"></span>`).join('');
    progEl.innerHTML =
      `<span class="prog-group"><span class="prog-label">Wave</span><span class="prog-dots">${waveDots}</span></span>` +
      `<span class="prog-group"><span class="prog-label">Trust</span><span class="prog-dots">${trustDots}</span></span>`;
  } else {
    progEl.innerHTML = '';
  }

  const row = $('closerow');
  if (S.state === 'FIRED') {
    $('verdict').textContent = "YOU'RE FIRED";
    $('verdict').className = 'verdict disp miss';
    const waveStr = S.wave_in_client ? `Wave ${S.wave_in_client}` : 'this run';
    const earnedStr = S.bankroll > 0 ? ` — ${dollars(S.bankroll)} earned before termination` : '';
    $('closedetail').innerHTML = `trust depleted on ${waveStr}${earnedStr}${diagHint}`;
    $('nextup').innerHTML = '';
    row.innerHTML = `<button class="btn" id="rb">Run it back</button><a class="btn sec" href="index.html">Return home</a>`;
  } else if (S.state === 'RUN_WON') {
    $('verdict').textContent = 'ALL WAVES WON';
    $('verdict').className = 'verdict disp pass';
    $('closedetail').textContent = `${dollars(S.bankroll)} total fees · ${S.global_wave} wave${S.global_wave!==1?'s':''} · ${S.packs_opened||0} pack${(S.packs_opened||0)!==1?'s':''} · ${S.collection_size||0} cards`;
    $('nextup').innerHTML = '';
    row.innerHTML = `<button class="btn" id="rb">Run it back</button><a class="btn sec" href="index.html">Return home</a>`;
  } else if (passed) {
    row.innerHTML =
      `<button class="btn" id="nb">${nextCtaLabel}</button>` +
      `<button class="btn sec" id="rb">Run it back</button>`;
    $('nb').onclick = onNextBrief;
  } else {
    const trustSub = trust === 1
      ? '<small class="btn-sub btn-sub-last">last trust</small>'
      : '<small class="btn-sub">−1 trust</small>';
    row.innerHTML =
      `<button class="btn" id="rb">Run it back</button>` +
      `<button class="btn sec" id="nb">${nextCtaLabel}${trustSub}</button>`;
    $('nb').onclick = onNextBrief;
  }
  $('rb').onclick = onRunBack;
  go('close');
}

export function runNewsstand(S, { dollars, go, onNext }) {
  const cards = S.last_pack || [];
  const waveN = S.global_wave || 1;
  $('ns-wave').innerHTML =
    `<span class="ns-wave-title">Wave ${waveN} complete</span>` +
    `<span class="ns-wave-sub">${cards.length} new card${cards.length !== 1 ? 's' : ''} unlocked</span>`;
  $('ns-cards').innerHTML = cards.map((id, i) => {
    const enables = conceptsFor(id);
    const enablesHtml = enables.length
      ? `<span class="nscard-enables">${enables.map(n => `<span>${n}</span>`).join('')}</span>`
      : '';
    return `<div class="nscard" style="animation-delay:${i*220}ms"><span class="nscard-label">${cardLabel(id)}</span><span class="nscard-sub">${cardCategory(id)}</span>${enablesHtml}</div>`;
  }).join('');
  cards.forEach((_, i) => setTimeout(() => sfxDeal(), i*220 + 80));
  const btn = $('ns-next');
  btn.textContent = `Begin wave ${waveN + 1} →`;
  btn.onclick = onNext;
  btn.style.opacity = '0';
  btn.style.pointerEvents = 'none';
  const revealMs = cards.length * 220 + 500;
  setTimeout(() => { btn.style.transition = 'opacity .4s'; btn.style.opacity = ''; btn.style.pointerEvents = ''; }, revealMs);
  go('newsstand');
}
