// Generate the Workbooks VS Code color themes from app.css tokens — the ground-up theming path (B2 in
// registry/ide-source-graph.work). Reads the @theme (base/light) + [data-theme="dark"] token blocks, builds a
// full ~600-key color theme + syntax tokenColors mapped onto our palette, and writes a committed JS artifact
// the workbench registers via the theme service. Single source of truth = app.css → no drift.
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('..', import.meta.url))
const css = readFileSync(root + 'src/app.css', 'utf8')

// pull `--color-x: #hex;` pairs out of the FIRST block matching `label {` whose body actually defines tokens.
// (label can occur in non-token contexts — e.g. `@custom-variant dark (...[data-theme="dark"]...)` — so we
// scan every occurrence and take the one containing `--color-`.)
function block(label) {
  let from = 0
  while (true) {
    const i = css.indexOf(label, from)
    if (i < 0) throw new Error('token block not found: ' + label)
    const open = css.indexOf('{', i)
    if (open < 0) throw new Error('no block for: ' + label)
    let depth = 0, end = open
    for (let j = open; j < css.length; j++) { if (css[j] === '{') depth++; else if (css[j] === '}') { depth--; if (!depth) { end = j; break } } }
    const body = css.slice(open + 1, end)
    const out = {}
    for (const m of body.matchAll(/--color-([a-z]+)\s*:\s*(#[0-9a-fA-F]{3,8})/g)) out[m[1]] = m[2]
    if (Object.keys(out).length) return out
    from = end + 1
  }
}

const base = block('@theme')                      // light/base values
const darkOverrides = block('[data-theme="dark"]')
const dark = { ...base, ...darkOverrides }
const light = { ...base }

// add alpha to a #rrggbb
const a = (hex, aa) => hex.length === 7 ? hex + aa : hex

function colors(t) {
  return {
    // general
    foreground: t.ink,
    'icon.foreground': t.dim,
    focusBorder: a(t.bloom, '00'),
    contrastBorder: t.line,
    'widget.border': t.line,
    'widget.shadow': '#00000040',
    'sash.hoverBorder': t.bloom,
    'selection.background': a(t.bloom, '40'),
    errorForeground: t.bad,
    descriptionForeground: t.dim,
    // editor
    'editor.background': t.well,
    'editorGroup.emptyBackground': t.well,
    'editorPane.background': t.well,
    'editor.foreground': t.ink,
    'editorLineNumber.foreground': t.line,
    'editorLineNumber.activeForeground': t.dim,
    'editorCursor.foreground': t.bloom,
    'editor.selectionBackground': t.line,
    'editor.inactiveSelectionBackground': a(t.line, 'aa'),
    'editor.lineHighlightBackground': a(t.card, '66'),
    'editor.lineHighlightBorder': '#00000000',
    'editorWhitespace.foreground': t.line,
    'editorIndentGuide.background1': t.line,
    'editorIndentGuide.activeBackground1': t.dim,
    'editorWidget.background': t.card,
    'editorWidget.border': t.line,
    'editorHoverWidget.background': t.card,
    'editorHoverWidget.border': t.line,
    'editorSuggestWidget.background': t.card,
    'editorSuggestWidget.border': t.line,
    'editorSuggestWidget.selectedBackground': t.line,
    'editorGutter.background': t.well,
    'editorBracketMatch.background': a(t.line, '00'),
    'editorBracketMatch.border': t.dim,
    'editorError.foreground': t.bad,
    'editorWarning.foreground': t.amber,
    'editorInfo.foreground': t.sky,
    // sidebar
    'sideBar.background': t.paper,
    'sideBar.foreground': t.dim,
    'sideBar.border': t.line,
    'sideBarSectionHeader.background': t.paper,
    'sideBarSectionHeader.foreground': t.ink,
    'sideBarSectionHeader.border': t.line,
    'sideBarTitle.foreground': t.dim,
    // activity bar
    'activityBar.background': t.well,
    'activityBar.foreground': t.ink,
    'activityBar.inactiveForeground': t.dim,
    'activityBar.border': t.line,
    'activityBar.activeBorder': t.bloom,
    'activityBarBadge.background': t.bloom,
    'activityBarBadge.foreground': t.well,
    // lists / trees
    'list.activeSelectionBackground': t.line,
    'list.activeSelectionForeground': t.ink,
    'list.inactiveSelectionBackground': t.card,
    'list.inactiveSelectionForeground': t.ink,
    'list.hoverBackground': a(t.card, 'cc'),
    'list.focusBackground': t.line,
    'list.highlightForeground': t.bloom,
    'tree.indentGuidesStroke': t.line,
    // tabs / editor groups
    'editorGroupHeader.tabsBackground': t.paper,
    'editorGroupHeader.tabsBorder': t.line,
    'editorGroup.border': t.line,
    'tab.activeBackground': t.well,
    'tab.activeForeground': t.ink,
    'tab.inactiveBackground': t.paper,
    'tab.inactiveForeground': t.dim,
    'tab.border': t.line,
    'tab.activeBorder': '#00000000',
    'tab.activeBorderTop': t.sky,
    'tab.hoverBackground': t.card,
    // panel
    'panel.background': t.paper,
    'panel.border': t.line,
    'panelTitle.activeForeground': t.ink,
    'panelTitle.inactiveForeground': t.dim,
    'panelTitle.activeBorder': t.bloom,
    // status bar
    'statusBar.background': t.paper,
    'statusBar.foreground': t.dim,
    'statusBar.border': t.line,
    'statusBar.noFolderBackground': t.paper,
    'statusBarItem.hoverBackground': t.card,
    'statusBarItem.remoteBackground': t.bloom,
    'statusBarItem.remoteForeground': t.well,
    // title bar
    'titleBar.activeBackground': t.paper,
    'titleBar.activeForeground': t.dim,
    'titleBar.inactiveBackground': t.paper,
    'titleBar.border': t.line,
    // inputs / dropdowns
    'input.background': t.well,
    'input.foreground': t.ink,
    'input.border': t.line,
    'input.placeholderForeground': t.dim,
    'inputOption.activeBorder': t.bloom,
    'dropdown.background': t.card,
    'dropdown.foreground': t.ink,
    'dropdown.border': t.line,
    // buttons / badges
    'button.background': t.bloom,
    'button.foreground': t.well,
    'button.hoverBackground': t.bloomd,
    'button.secondaryBackground': t.card,
    'button.secondaryForeground': t.ink,
    'badge.background': t.bloom,
    'badge.foreground': t.well,
    'progressBar.background': t.bloom,
    // quick input / command palette
    'quickInput.background': t.card,
    'quickInput.foreground': t.ink,
    'quickInputList.focusBackground': t.line,
    'pickerGroup.foreground': t.dim,
    'pickerGroup.border': t.line,
    // breadcrumb
    'breadcrumb.foreground': t.dim,
    'breadcrumb.focusForeground': t.ink,
    'breadcrumb.activeSelectionForeground': t.ink,
    'breadcrumb.background': t.well,
    'breadcrumbPicker.background': t.card,
    // scrollbar
    'scrollbar.shadow': '#00000000',
    'scrollbarSlider.background': a(t.line, 'aa'),
    'scrollbarSlider.hoverBackground': a(t.dim, '66'),
    'scrollbarSlider.activeBackground': t.dim,
    // menus
    'menu.background': t.card,
    'menu.foreground': t.ink,
    'menu.selectionBackground': t.line,
    'menu.border': t.line,
    'menubar.selectionBackground': t.card,
    // notifications
    'notifications.background': t.card,
    'notifications.foreground': t.ink,
    'notifications.border': t.line,
    'notificationCenterHeader.background': t.paper,
    'notificationLink.foreground': t.sky,
    // terminal — ANSI mapped to our pastels
    'terminal.background': t.well,
    'terminal.foreground': t.ink,
    'terminalCursor.foreground': t.bloom,
    'terminal.selectionBackground': t.line,
    'terminal.ansiBlack': t.well,
    'terminal.ansiRed': t.bad,
    'terminal.ansiGreen': t.bloom,
    'terminal.ansiYellow': t.amber,
    'terminal.ansiBlue': t.sky,
    'terminal.ansiMagenta': t.fuchsia,
    'terminal.ansiCyan': t.mint,
    'terminal.ansiWhite': t.ink,
    'terminal.ansiBrightBlack': t.dim,
    'terminal.ansiBrightRed': t.bad,
    'terminal.ansiBrightGreen': t.bloomd,
    'terminal.ansiBrightYellow': t.cream,
    'terminal.ansiBrightBlue': t.blue,
    'terminal.ansiBrightMagenta': t.violet,
    'terminal.ansiBrightCyan': t.sky,
    'terminal.ansiBrightWhite': t.ink
  }
}

function tokenColors(t) {
  const s = (scope, foreground, fontStyle) => ({ scope, settings: fontStyle ? { foreground, fontStyle } : { foreground } })
  return [
    s('comment', t.dim, 'italic'),
    s(['string', 'string.quoted', 'constant.other.symbol'], t.sage),
    s(['keyword', 'storage', 'storage.type', 'keyword.control'], t.violet),
    s(['constant.numeric', 'constant.numeric.integer'], t.peach),
    s(['entity.name.type', 'support.type', 'support.class', 'entity.name.class'], t.sky),
    s(['entity.name.function', 'support.function', 'meta.function-call'], t.mint),
    s(['variable', 'variable.other', 'variable.parameter'], t.ink),
    s(['constant.language', 'constant.character', 'support.constant'], t.amber),
    s(['entity.name.tag'], t.sky),
    s(['entity.other.attribute-name'], t.fuchsia),
    s(['punctuation', 'meta.brace', 'punctuation.definition'], t.dim),
    s(['keyword.operator'], t.dim),
    s(['markup.heading', 'entity.name.section'], t.sky, 'bold'),
    s(['markup.bold'], t.ink, 'bold'),
    s(['markup.italic'], t.ink, 'italic'),
    s(['markup.inline.raw', 'markup.raw'], t.sage)
  ]
}

const theme = (t, type, name) => ({ name, type, colors: colors(t), tokenColors: tokenColors(t), semanticHighlighting: true })

const out = {
  dark: theme(dark, 'dark', 'Workbooks Dark'),
  light: theme(light, 'light', 'Workbooks Light')
}

const banner = '// GENERATED by tools/gen-ide-theme.mjs from src/app.css tokens — do not edit by hand.\n' +
  '// Regenerate: node tools/gen-ide-theme.mjs. Single source of truth = app.css (no drift).\n'
writeFileSync(root + 'src/lib/ide/theme.generated.js', banner + 'export const themes = ' + JSON.stringify(out, null, 2) + '\n')
console.log('wrote src/lib/ide/theme.generated.js — dark', Object.keys(out.dark.colors).length, 'colors,', out.dark.tokenColors.length, 'token rules')
