const SOUND_KEY   = 'adbuy.sound';
const HAPTICS_KEY = 'adbuy.haptics';
const MOTION_KEY  = 'adbuy.reduce-motion';

export const isSoundEnabled        = () => localStorage.getItem(SOUND_KEY) !== 'false';
export const isHapticsEnabled      = () => localStorage.getItem(HAPTICS_KEY) !== 'false';
export const isReduceMotionEnabled = () => localStorage.getItem(MOTION_KEY) === 'true'
  || window.matchMedia('(prefers-reduced-motion: reduce)').matches;

export const setSound        = v => localStorage.setItem(SOUND_KEY, String(v));
export const setHaptics      = v => localStorage.setItem(HAPTICS_KEY, String(v));
export const setReduceMotion = v => {
  localStorage.setItem(MOTION_KEY, String(v));
  document.body.classList.toggle('reduce-motion', !!v);
};
