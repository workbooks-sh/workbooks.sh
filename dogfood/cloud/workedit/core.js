// workedit/core — the shareable `.work` editor island. `createEditor(mount, opts)` returns a
// controller. ONE CodeMirror 6 surface (the plain text is source-of-truth; there is no second
// document model — "WYSIWYG" is a decoration layer added on top, never a separate editor). The island
// owns CM loading, dirty tracking, ⌘S, and the `.work` syntax layer; the host supplies onSave/onChange
// and renders its own chrome (save bar, tabs). Framework-agnostic vanilla JS, themed via --wke-* vars —
// same island convention as wbchat (createX(el, opts) -> controller).
//
//   createEditor(mount, {
//     doc,            // initial text
//     path,           // file path (enables the .work syntax layer + is informational)
//     readOnly,       // boolean
//     onSave(text),   // async; return false to signal failure (keeps dirty); throw is treated as fail
//     onDirtyChange(dirty), onChange(text),
//     resolveModule(url),  // optional: map the island's own relative imports (e.g. cache-busting)
//   }) -> {
//     view, getDoc(), setDoc(s), isDirty(), markSaved(), save(), setReadOnly(b), focus(), destroy()
//   }

let _cm = null;
function loadCM() {
  if (_cm) return _cm;
  // esm.sh shares one @codemirror/state + view across these sibling imports (same bare specifiers).
  _cm = Promise.all([
    import('https://esm.sh/@codemirror/view@6'),
    import('https://esm.sh/@codemirror/state@6'),
    import('https://esm.sh/@codemirror/commands@6'),
  ]).then(function (mods) { return { view: mods[0], state: mods[1], cmds: mods[2] }; });
  return _cm;
}

const isWork = (p) => /\.work$/i.test(p || '');

export async function createEditor(mount, opts = {}) {
  const { view, state, cmds } = await loadCM();
  const EditorView = view.EditorView;
  const rv = opts.resolveModule || ((u) => u);

  let dirty = false;
  function setDirty(b) { if (b === dirty) return; dirty = b; try { opts.onDirtyChange && opts.onDirtyChange(b); } catch (_) {} }

  let saving = false;
  async function save() {
    if (!dirty || saving || !opts.onSave) return;
    saving = true;
    try { const ok = await opts.onSave(getDoc()); if (ok !== false) setDirty(false); }
    catch (_) { /* host surfaces the error; stay dirty so a retry is possible */ }
    finally { saving = false; }
  }

  // A read/write compartment so setReadOnly can reconfigure without rebuilding the editor.
  const editableComp = new state.Compartment();

  const exts = [
    view.lineNumbers(),
    view.highlightActiveLine(),
    cmds.history(),
    // ⌘S lives in the editor (CM6 doesn't bind it) so it works when the editor has focus.
    view.keymap.of([{ key: 'Mod-s', preventDefault: true, run: () => { save(); return true; } }]
      .concat(cmds.defaultKeymap, cmds.historyKeymap)),
    EditorView.updateListener.of((u) => {
      if (!u.docChanged) return;
      setDirty(true);
      if (opts.onChange) { try { opts.onChange(getDoc()); } catch (_) {} }
    }),
    EditorView.theme({ '&': { height: '100%', fontSize: '12.5px' } }),
    editableComp.of(EditorView.editable.of(!opts.readOnly)),
  ];

  // The `.work` syntax layer (P1) — a ViewPlugin over THIS view's namespace (one state instance).
  if (isWork(opts.path)) {
    try { const wk = await import(rv('./lang-stream.js')); exts.push(...wk.workHighlightFromView(view)); }
    catch (e) { try { console.warn('[workedit] .work highlight unavailable', e); } catch (_) {} }
  }

  const editor = new EditorView({ doc: opts.doc || '', extensions: exts, parent: mount });
  function getDoc() { return editor.state.doc.toString(); }

  return {
    view: editor,
    getDoc,
    setDoc(s) { editor.dispatch({ changes: { from: 0, to: editor.state.doc.length, insert: s || '' } }); setDirty(false); },
    isDirty: () => dirty,
    markSaved: () => setDirty(false),
    save,
    setReadOnly(b) { editor.dispatch({ effects: editableComp.reconfigure(EditorView.editable.of(!b)) }); },
    focus() { editor.focus(); },
    destroy() { editor.destroy(); },
  };
}
