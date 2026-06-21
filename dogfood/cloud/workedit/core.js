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
  // esm.sh shares one @codemirror/state + view across these sibling imports (same bare specifiers) —
  // verified: lint + autocomplete facets apply against the host view (no duplicate-state trap).
  _cm = Promise.all([
    import('https://esm.sh/@codemirror/view@6'),
    import('https://esm.sh/@codemirror/state@6'),
    import('https://esm.sh/@codemirror/commands@6'),
    import('https://esm.sh/@codemirror/autocomplete@6'),
    import('https://esm.sh/@codemirror/lint@6'),
  ]).then(function (mods) { return { view: mods[0], state: mods[1], cmds: mods[2], ac: mods[3], lint: mods[4] }; });
  return _cm;
}

const isWork = (p) => /\.work$/i.test(p || '');

export async function createEditor(mount, opts = {}) {
  const { view, state, cmds, ac, lint } = await loadCM();
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

  // Compartments so we can reconfigure live (read/write) without rebuilding the editor.
  const editableComp = new state.Compartment();
  const liveComp = new state.Compartment();          // the Live (WYSIWYG) decoration layer (P4)

  const exts = [
    view.lineNumbers(),
    view.highlightActiveLine(),
    cmds.history(),
    // ⌘S lives in the editor (CM6 doesn't bind it) so it works when the editor has focus.
    view.keymap.of([{ key: 'Mod-s', preventDefault: true, run: () => { save(); return true; } }]
      .concat(cmds.defaultKeymap, cmds.historyKeymap, ac.completionKeymap, lint.lintKeymap)),
    EditorView.updateListener.of((u) => {
      if (!u.docChanged) return;
      setDirty(true);
      if (opts.onChange) { try { opts.onChange(getDoc()); } catch (_) {} }
    }),
    EditorView.theme({ '&': { height: '100%', fontSize: '12.5px' } }),
    editableComp.of(EditorView.editable.of(!opts.readOnly)),
    liveComp.of([]),
  ];

  // The `.work` layers: syntax highlight (P1), autocomplete (kinds + do/end snippets), and lint
  // (diagnostics from the host-supplied lintSource — the nexus parser via /cloud/parse).
  if (isWork(opts.path)) {
    try { const wk = await import(rv('./lang-stream.js')); exts.push(...wk.workHighlightFromView(view)); }
    catch (e) { try { console.warn('[workedit] .work highlight unavailable', e); } catch (_) {} }
    try { const comp = await import(rv('./complete.js')); exts.push(comp.workCompletion(ac)); }
    catch (e) { try { console.warn('[workedit] .work completion unavailable', e); } catch (_) {} }
    if (typeof opts.lintSource === 'function') {
      const toDiags = (raw, doc) => (raw || []).map((d) => {
        const line = Math.max(1, Math.min(doc.lines, d.line || 1));
        const ln = doc.line(line);
        const from = ln.from + Math.max(0, (d.col || 1) - 1);
        const endLn = d.endLine ? doc.line(Math.max(1, Math.min(doc.lines, d.endLine))) : ln;
        let to = d.endCol ? endLn.from + (d.endCol - 1) : ln.to;
        if (to <= from) to = Math.min(doc.length, from + 1);
        return { from, to, severity: d.severity || 'warning', message: d.message || '' };
      });
      exts.push(
        lint.linter(async (v) => {
          let raw = [];
          try { raw = await opts.lintSource(v.state.doc.toString()); } catch (_) {}
          return toDiags(raw, v.state.doc);
        }, { delay: 400 }),
        lint.lintGutter(),
      );
    }
  }

  const editor = new EditorView({ doc: opts.doc || '', extensions: exts, parent: mount });
  function getDoc() { return editor.state.doc.toString(); }

  // Live (WYSIWYG) layer — only meaningful for .work; loaded lazily on first enable.
  let mode = 'source';
  let _liveExts = null;
  async function setMode(m) {
    const next = m === 'live' && isWork(opts.path) ? 'live' : 'source';
    if (next === mode) return mode;
    if (next === 'live' && !_liveExts) {
      try { const lv = await import(rv('./live.js')); _liveExts = lv.workLiveFromView(view); }
      catch (e) { try { console.warn('[workedit] live mode unavailable', e); } catch (_) {} return mode; }
    }
    editor.dispatch({ effects: liveComp.reconfigure(next === 'live' ? _liveExts : []) });
    mode = next;
    return mode;
  }

  const controller = {
    view: editor,
    getDoc,
    setDoc(s) { editor.dispatch({ changes: { from: 0, to: editor.state.doc.length, insert: s || '' } }); setDirty(false); },
    isDirty: () => dirty,
    markSaved: () => setDirty(false),
    save,
    setReadOnly(b) { editor.dispatch({ effects: editableComp.reconfigure(EditorView.editable.of(!b)) }); },
    getMode: () => mode,
    setMode,
    focus() { editor.focus(); },
    destroy() { editor.destroy(); },
  };
  if (opts.mode === 'live') setMode('live');
  return controller;
}
