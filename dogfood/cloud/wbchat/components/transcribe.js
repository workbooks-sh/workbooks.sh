// wbchat/components/transcribe — composer "dictate" (microphone) button.
// Real, browser-native transcription via the Web Speech API (SpeechRecognition / webkitSpeechRecognition).
// Click to start listening; recognized text is streamed into the composer via ctx.insertText. Click
// again (or auto-end) to stop. Self-contained: own CSS reusing the core .wbc-tool class. Returns null
// when the browser has no speech recognition (the button simply doesn't appear) or ctx.insertText
// isn't available — never a dead control.
import { registerComposerButton, el, injectStyle } from '../core.js';

injectStyle('transcribe', `
  .wbc-mic.live { color: #e07a5f; background: color-mix(in srgb, #e07a5f 16%, transparent); }
  .wbc-mic.live svg { animation: wbc-mic-pulse 1.1s ease-in-out infinite; }
  @keyframes wbc-mic-pulse { 0%,100% { opacity: 1; } 50% { opacity: .45; } }
`);

const MIC = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2"/><line x1="12" x2="12" y1="19" y2="22"/></svg>';

registerComposerButton((ctx) => {
  const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!SR || typeof ctx.insertText !== 'function') return null;

  const btn = el('button', {
    type: 'button', class: 'wbc-tool wbc-mic', title: 'Dictate (speech to text)', 'aria-label': 'Dictate',
    html: MIC,
  });

  let rec = null;          // active recognition instance (null = idle)
  let committed = '';      // text already inserted this session (so we only append the delta)

  function stop() { if (rec) { try { rec.stop(); } catch (_) {} } }
  function setLive(on) { btn.classList.toggle('live', on); btn.title = on ? 'Stop dictation' : 'Dictate (speech to text)'; }

  function start() {
    rec = new SR();
    rec.continuous = true;
    rec.interimResults = false;       // only commit finalized phrases into the composer
    rec.lang = (navigator.language || 'en-US');
    committed = '';
    rec.onresult = (e) => {
      let finalText = '';
      for (let i = e.resultIndex; i < e.results.length; i++) {
        if (e.results[i].isFinal) finalText += e.results[i][0].transcript;
      }
      const delta = finalText.slice(committed.length);
      if (delta.trim()) { ctx.insertText(delta.trim()); committed = finalText; }
    };
    rec.onerror = () => { setLive(false); rec = null; };
    rec.onend = () => { setLive(false); rec = null; };
    try { rec.start(); setLive(true); } catch (_) { rec = null; setLive(false); }
  }

  btn.addEventListener('click', () => { rec ? stop() : start(); });
  return btn;
});
