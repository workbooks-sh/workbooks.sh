// Shared click-to-copy handler for .install-card-cta buttons.
// Each button has data-prompt (the text written to the clipboard
// when clicked) and data-name (the harness name, used in the
// success label). One file, included from every harness docs page,
// so updates land everywhere at once.

(() => {
  function wire() {
    document.querySelectorAll('.install-card-cta[data-prompt]').forEach((btn) => {
      if (btn.dataset.wired === '1') return;
      btn.dataset.wired = '1';
      btn.addEventListener('click', async () => {
        const prompt = btn.dataset.prompt;
        const name = btn.dataset.name || 'your AI tool';
        const label = btn.querySelector('span');
        const original = label ? label.textContent : 'Copy install prompt';
        try {
          await navigator.clipboard.writeText(prompt);
          if (label) label.textContent = 'Copied — paste into ' + name;
          btn.classList.add('copied');
          setTimeout(() => {
            if (label) label.textContent = original;
            btn.classList.remove('copied');
          }, 1800);
        } catch {
          if (label) label.textContent = 'Press ⌘C to copy';
          setTimeout(() => {
            if (label) label.textContent = original;
          }, 1800);
        }
      });
    });
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', wire);
  } else {
    wire();
  }
})();
