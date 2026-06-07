const $ = id => document.getElementById(id);

export function syncGoalModal(S, CLIENTS, dollars){
  $('ghtitle').textContent = 'This Week\'s Goal — ' + (S.is_boss ? `Wave ${S.wave_in_client} · Final` : `Wave ${S.wave_in_client}`);
  $('gclient').textContent = CLIENTS[S.client] || S.client || '—';
  $('gtarget').textContent = dollars(S.target) + ' revenue';
  const floorRow = $('gfloor').closest('.gline');
  if (floorRow) floorRow.style.display = S.spend_floor > 0 ? '' : 'none';
  $('gfloor').textContent  = dollars(S.spend_floor) + ' / week';
  $('gfee').textContent    = '+' + dollars(S.fee);
  $('gmiss').textContent   = S.is_boss ? 'FIRED — no second chances' : (S.trust <= 1 ? 'FIRED — last trust' : `lose a trust (${S.trust||0} left)`);
  const trustDots = Array.from({length:3}, (_,i) => i < (S.trust||0) ? '●' : '○').join(' ');
  const waveLabel = S.is_boss ? 'final wave' : `wave ${S.wave_in_client||1} of 3`;
  $('gladder').textContent = `trust ${trustDots} · ${waveLabel}`;

  const paceEl = $('gpace');
  if (S.state === 'FLIGHT' && S.day > 0 && S.target > 0) {
    const daysLeft = Math.max(0, (S.total_days||5) - S.day - 1);
    const dailyAvg = S.revenue / S.day;
    const projected = S.revenue + dailyAvg * daysLeft;
    const pct = projected / S.target;
    const [label, cls] = pct >= 1 ? ['on track', 'pace-ok']
                       : pct >= 0.7 ? ['behind pace', 'pace-warn']
                       : ['at risk', 'pace-bad'];
    paceEl.innerHTML = `<span class="pace-label ${cls}">${label}</span><span class="pace-proj">est. ${dollars(Math.round(projected))} of ${dollars(S.target)}</span>`;
  } else {
    paceEl.innerHTML = '';
  }
}

export function wireGoal(){
  window.openGoal  = () => $('goalmodal').classList.add('on');
  window.closeGoal = (ev) => {
    if (ev && ev.target.closest && ev.target.closest('.gpanel')) return;
    $('goalmodal').classList.remove('on');
  };
}
