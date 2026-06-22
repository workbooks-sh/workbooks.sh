// wbchat/components/attachments — composer "attach files" button.
// Adds a paperclip button to the composer toolbar (left of send). On click it opens a hidden
// multiple <input type=file>; each chosen file is handed to ctx.addFile(file). The core owns the
// chip tray + send payload (file parts) — this module only contributes the button + picker.
// Reference: ai-elements PromptInput attachments. Self-contained: own CSS themed via --wbc-* vars,
// reusing the core .wbc-tool button class for visual parity with other composer add-ons.
import { registerComposerButton, el, injectStyle } from '../core.js';

injectStyle('attachments', `
  .wbc-attach { position: relative; }
  .wbc-attach-input { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px;
    overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; border: 0; }
`);

const PAPERCLIP = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48"/></svg>';

registerComposerButton((ctx) => {
  const input = el('input', {
    type: 'file', multiple: '', class: 'wbc-attach-input', tabindex: '-1', 'aria-hidden': 'true',
    onChange: (e) => {
      const files = Array.from(e.target.files || []);
      files.forEach(f => ctx.addFile(f));
      e.target.value = ''; // reset so re-picking the same file re-fires change
    },
  });
  const btn = el('button', {
    type: 'button', class: 'wbc-tool', title: 'Add context', 'aria-label': 'Add context',
    html: PAPERCLIP,
    // Prefer the host's context picker (searchable multi-select over files / workspaces / spaces); fall
    // back to the native file dialog when no host picker is wired.
    onClick: () => {
      if (ctx.pickContext) {
        try {
          Promise.resolve(ctx.pickContext()).then(items => { (items || []).forEach(it => ctx.addFile(it)); });
          return;
        } catch (e) { /* fall through to native */ }
      }
      input.click();
    },
  });
  return el('span', { class: 'wbc-attach' }, [btn, input]);
}, { side: 'right' });
