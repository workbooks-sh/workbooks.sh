import { ambient, sleep } from './ceremony.js';
import { sfxSlotPop, sfxBell } from './audio.js';
import { whisperPick, voiceSuccess } from './haptics.js';

const $ = id => document.getElementById(id);
const dollars = cents => '$' + Math.round((cents||0)/100).toLocaleString();

export async function runFocusBeat(m, i, after, prev, artUrl, nap = ms => sleep(ms)){
  const ad = (after.ads && after.ads[i]) || { rev:0, spend:0, killed:false, imps:0 };
  const p = prev[i] || { rev:0, spend:0 };
  const gainCents = ad.rev - p.rev;
  const hit = gainCents > 0 && !ad.killed;
  const abTag = i < 2 ? `<span class="bc-abtag">${'AB'[i]}</span>` : '';
  const impsStr = ad.imps >= 1000 ? `${(ad.imps/1000).toFixed(1)}k views` : ad.imps > 0 ? `${ad.imps} views` : '';
  const dudMsg = ad.killed ? 'stopped' : after.day <= 1 ? 'warming up' : 'quiet day';

  const focus = $('focus');
  focus.innerHTML = `
    <div class="bigcard" id="big">
      ${abTag}
      <div class="float" id="bigfloat">+${dollars(gainCents)}</div>
      <div class="dud" id="bigdud">${dudMsg}</div>
      <div class="bart" style="background-image:url('${artUrl(m.art)}')"></div>
      <div class="slots">${m.slots.map(s=>`<div class="ms">${s}</div>`).join('')}</div>
      <h4>${m.name}</h4>
      <div class="nightrev" id="bigrev">${dollars(p.rev)}</div>
      ${impsStr ? `<div class="bc-imps">${impsStr}</div>` : ''}
    </div>`;

  const slots = focus.querySelectorAll('.ms');
  ambient(() => slots.forEach((s, k) => setTimeout(() => { s.classList.add('pulse'); sfxSlotPop(); whisperPick(); }, 420 + k*170)));

  await nap(420 + slots.length*170);

  if (hit){
    $('bigfloat').classList.add('go');
    const el = $('bigrev'), from = p.rev, to = ad.rev, t0 = performance.now();
    (function tickup(now){
      const t = Math.min(1, (now - t0) / 450);
      el.textContent = dollars(from + (to - from) * t);
      if (t < 1) requestAnimationFrame(tickup);
    })(performance.now());
  } else {
    $('bigdud').classList.add('go');
  }

  await nap(480);
  $('big').classList.add('exit');
  await nap(280);
  const roasStr = ad.roas_x1000 > 0 ? `<span class="minidone-roas">return ${(ad.roas_x1000/1000).toFixed(1)}×</span>` : '';
  $('doneRow').innerHTML +=
    `<div class="minidone" style="background-image:url('${artUrl(m.art)}')">` +
    (i < 2 ? `<span class="minidone-ab">${'AB'[i]}</span>` : '') +
    `<b>+${dollars(gainCents)}</b>${roasStr}</div>`;
}

export function nightChyron(after, bell) {
  if (after.state === 'NEWSSTAND') return 'week closes — running the numbers';
  if (bell) return `${'AB'[bell.winner-1]||'?'} pulled clear — the data is in`;
  if (after.day <= 1) return 'day one — market still warming up';
  const dLeft = Math.max(0, (after.total_days||5) - after.day - 1);
  const proj = dLeft > 0 ? after.revenue + (after.revenue / after.day) * dLeft : after.revenue;
  const goalDay = dLeft === 0;
  if (proj >= (after.target||1) * 1.15) return goalDay ? 'ahead of target — close it out' : 'well ahead of target — keep the pressure on';
  if (proj >= (after.target||1)) return goalDay ? 'on pace — hold the line today' : 'on pace — you\'re tracking to hit it';
  if (proj >= (after.target||1) * 0.65) return goalDay ? 'behind — squeeze every move today' : 'behind pace — build another ad or let these run';
  return goalDay ? 'at risk — last shot · make every move count' : 'at risk — build a new ad while you still can';
}

// skip: { value: bool } — mutable; dashboard sets true on recap tap to skip animations.
// onDone(after): called with final state when ceremony ends normally.
// onClose(): called when autopsy fires (week ended).
export async function runNight(after, prev, bell, autopsy, {
  myAds, pinned, winnerIdx, artUrl, skip, onDone, onClose,
}) {
  skip.value = false;
  const nap = ms => skip.value ? Promise.resolve() : sleep(ms);
  const total = after.total_days || 5;
  const dayNo = Math.max(1, Math.min(after.day, total));
  const WD_FULL = ['Monday','Tuesday','Wednesday','Thursday','Friday'];
  const dayName = WD_FULL[dayNo - 1] || `Day ${dayNo}`;
  $('rtitle').textContent = after.state === 'NEWSSTAND' ? `${dayName} — week close` : `${dayName} night`;
  $('rsub').textContent = nightChyron(after, bell);
  $('doneRow').innerHTML = '';
  $('rtotals').classList.remove('show');
  $('focus').innerHTML = '';
  const recap = $('recap');
  recap.classList.add('on');
  requestAnimationFrame(() => recap.classList.add('vis'));
  await nap(250);

  for (let i = 0; i < myAds.length; i++) {
    await runFocusBeat(myAds[i], i, after, prev, artUrl, nap);
  }

  let dRev = 0, dSp = 0;
  (after.ads||[]).forEach((ad, i) => {
    const p = prev[i] || { rev:0, spend:0 };
    dRev += ad.rev - p.rev; dSp += ad.spend - p.spend;
  });
  const totals = $('rtotals');
  const nr = dSp > 0 ? dRev / dSp : 0;
  const nrCls = nr >= 2 ? 'roas-good' : nr >= 1 ? 'roas-ok' : 'roas-bad';
  const nightRoas = dSp > 0 ? ` · return <b class="roasv ${nrCls}">${nr.toFixed(2)}×</b>` : '';
  const weekPace = after.target > 0 ? ` · week <b>${dollars(after.revenue)}</b> of ${dollars(after.target)}` : '';
  totals.innerHTML = `spent ${dollars(dSp)} · earned <em>${dollars(dRev)}</em>${nightRoas}${weekPace}`;
  totals.classList.add('show');

  if (bell && !skip.value){
    const pinSuffix = pinned ? (bell.verdict === 'CONFIRMED' ? ' — CALLED IT' : ' — WRONG CALL') : '';
    $('stamptext').textContent = `${'AB'[winnerIdx]||'A'} WINS${pinSuffix}`;
    await nap(500);
    sfxBell(); voiceSuccess();
    if (!skip.value){
      $('stamp').classList.add('show');
      await nap(1800);
      $('stamp').classList.remove('show');
    }
  } else {
    await nap(500);
  }

  recap.classList.remove('vis');
  await nap(380);
  recap.classList.remove('on');
  if (autopsy) { onClose(); return; }
  onDone(after);
}
