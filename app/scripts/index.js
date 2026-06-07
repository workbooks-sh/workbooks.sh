import { readSave, clearSave } from '../save.js';
import { isSoundEnabled, isHapticsEnabled, isReduceMotionEnabled, setSound, setHaptics, setReduceMotion } from './settings.js';

const save = await readSave();
if (!save || !save.brand || !save.brand.name) {
  setTimeout(() => { location.replace('brand-creator.html'); }, 400);
}
const c = document.getElementById('continue');
if (save && save.brand && save.brand.name) {
  const wk = save.week || 1;
  const bankStr = (save.bankroll > 0) ? ' · $' + Math.round(save.bankroll / 100).toLocaleString() : '';
  document.getElementById('continuesub').textContent = wk > 1
    ? save.brand.name + bankStr + ' · wave ' + wk
    : save.brand.name + ' · wave 1';
  document.getElementById('newgamesub').textContent = 'will overwrite ' + save.brand.name;
  if (save.display) {
    const d = save.display;
    const crest = document.querySelector('.crest');
    crest.style.background = d.bg || '';
    crest.style.color = d.mark || '';
    crest.querySelector('i').className = `ph-fill ph-${d.glyph}`;
    document.querySelector('.tag').textContent = d.name + ' · ad studio';
  }
} else {
  c.classList.add('disabled');
}

const $ = id => document.getElementById(id);

function syncToggles() {
  $('sndtoggle').classList.toggle('on', isSoundEnabled());
  $('haptoggle').classList.toggle('on', isHapticsEnabled());
  $('motoggle').classList.toggle('on', isReduceMotionEnabled());
}

window.openSettings = () => { $('settingsmodal').classList.add('on'); syncToggles(); };
window.closeSettings = ev => {
  if (ev && ev.target.closest && ev.target.closest('.spanel')) return;
  $('settingsmodal').classList.remove('on');
};
window.toggleSound   = () => { setSound(!isSoundEnabled()); syncToggles(); };
window.toggleHaptics = () => { setHaptics(!isHapticsEnabled()); syncToggles(); };
window.toggleMotion  = () => { setReduceMotion(!isReduceMotionEnabled()); syncToggles(); };
window.clearData = async () => {
  const btn = $('clearbtn');
  if (btn.dataset.confirm !== '1') {
    btn.textContent = 'Are you sure?';
    btn.dataset.confirm = '1';
    setTimeout(() => { btn.textContent = 'Clear'; delete btn.dataset.confirm; }, 3000);
    return;
  }
  await clearSave();
  location.reload();
};
