// IDE editor theme — our palette mapped onto monaco's color/token model. Values are the resolved dark/light
// token values from app.css (--color-well / paper / card / ink / dim / line + pastels). Hand-mirrored for the
// recon spike; the production path generates this from app.css so it can't drift (see registry/ide-shell.work,
// theming layer 1). Syntax tokens use our pastels so highlighting reads as part of the dash, not VS Code.
const DARK = {
  well: '0f1012', paper: '16171a', card: '1f2125', ink: 'ecebe5', dim: '8c9189', line: '2d2f34',
  bloom: '3fe081', mint: 'aee5c2', sky: 'a8d4f0', sage: 'c8e0b0', peach: 'f3c5a3', violet: 'd9c5f0',
  fuchsia: 'e8a9d0', amber: 'e0b34a'
}
const LIGHT = {
  well: 'ffffff', paper: 'f7f6f1', card: 'ffffff', ink: '1a1b1e', dim: '6a6f68', line: 'e7e5db',
  bloom: '149157', mint: '4a9e6a', sky: '3f7fb0', sage: '6a9e48', peach: 'b5703a', violet: '7c63cf',
  fuchsia: 'b04d8a', amber: 'c2861f'
}

function makeTheme(p, base) {
  return {
    base,
    inherit: true,
    rules: [
      { token: '', foreground: p.ink, background: p.well },
      { token: 'comment', foreground: p.dim, fontStyle: 'italic' },
      { token: 'keyword', foreground: p.violet },
      { token: 'string', foreground: p.sage },
      { token: 'number', foreground: p.peach },
      { token: 'type', foreground: p.sky },
      { token: 'function', foreground: p.mint },
      { token: 'variable', foreground: p.ink },
      { token: 'constant', foreground: p.amber },
      { token: 'tag', foreground: p.sky },
      { token: 'attribute.name', foreground: p.fuchsia },
      { token: 'delimiter', foreground: p.dim }
    ],
    colors: {
      'editor.background': '#' + p.well,
      'editor.foreground': '#' + p.ink,
      'editorLineNumber.foreground': '#' + p.line,
      'editorLineNumber.activeForeground': '#' + p.dim,
      'editor.lineHighlightBackground': '#' + p.card + '66',
      'editor.selectionBackground': '#' + p.line,
      'editorCursor.foreground': '#' + p.bloom,
      'editorIndentGuide.background1': '#' + p.line + '80',
      'editorWhitespace.foreground': '#' + p.line,
      'editorGutter.background': '#' + p.well,
      'editorWidget.background': '#' + p.card,
      'editorWidget.border': '#' + p.line,
      'scrollbarSlider.background': '#' + p.line + 'aa',
      'scrollbarSlider.hoverBackground': '#' + p.dim + '66',
      'focusBorder': '#' + p.bloom + '00'
    }
  }
}

export const THEMES = {
  'workbooks-dark': makeTheme(DARK, 'vs-dark'),
  'workbooks-light': makeTheme(LIGHT, 'vs')
}

// match the dash: <html data-theme="dark|light">
export function themeForDocument() {
  return document.documentElement.getAttribute('data-theme') === 'light' ? 'workbooks-light' : 'workbooks-dark'
}
