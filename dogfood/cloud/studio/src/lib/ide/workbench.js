// IDE workbench boot (epic wb-pntm) — the FULL VS Code workbench mounted in our Code cell. Mirrors the
// monaco-vscode-api "views" demo recipe: a complete-enough service-override set to CONSTRUCT the workbench
// parts, the worker map keyed by label, then manual attachPart into our own DOM cells so it lives inside the
// dash (not full-window). Backed by an in-memory FS seeded from the mock tree (fs.svelte.js). Terminal/run/
// search slots render now; wired to washy later (registry/ide-shell.work). Stripping = trimming this list.
import * as monaco from '@codingame/monaco-vscode-editor-api'
import { initialize, getService } from '@codingame/monaco-vscode-api/services'
import { ICommandService } from '@codingame/monaco-vscode-api/services'
import { registerExtension, ExtensionHostKind } from '@codingame/monaco-vscode-api/extensions'
import { themes } from './theme.generated.js'
import { iconTheme, iconFiles } from './icons.generated.js'

import getViewsServiceOverride, { Parts, attachPart, isPartVisibile, onPartVisibilityChange, isEditorPartVisible } from '@codingame/monaco-vscode-views-service-override'
import getFilesServiceOverride, { RegisteredFileSystemProvider, RegisteredMemoryFile, registerFileSystemOverlay } from '@codingame/monaco-vscode-files-service-override'
import getQuickAccessServiceOverride from '@codingame/monaco-vscode-quickaccess-service-override'
import getThemeServiceOverride from '@codingame/monaco-vscode-theme-service-override'
import getTextmateServiceOverride from '@codingame/monaco-vscode-textmate-service-override'
import getLanguagesServiceOverride from '@codingame/monaco-vscode-languages-service-override'
import getConfigurationServiceOverride, { initUserConfiguration } from '@codingame/monaco-vscode-configuration-service-override'
import getKeybindingsServiceOverride from '@codingame/monaco-vscode-keybindings-service-override'
import getExplorerServiceOverride from '@codingame/monaco-vscode-explorer-service-override'
import getSearchServiceOverride from '@codingame/monaco-vscode-search-service-override'
import getTerminalServiceOverride from '@codingame/monaco-vscode-terminal-service-override'
import getOutputServiceOverride from '@codingame/monaco-vscode-output-service-override'
import getLogServiceOverride from '@codingame/monaco-vscode-log-service-override'
import getExtensionServiceOverride from '@codingame/monaco-vscode-extensions-service-override'
import getModelServiceOverride from '@codingame/monaco-vscode-model-service-override'
import getNotificationServiceOverride from '@codingame/monaco-vscode-notifications-service-override'
import getDialogsServiceOverride from '@codingame/monaco-vscode-dialogs-service-override'
import getBannerServiceOverride from '@codingame/monaco-vscode-view-banner-service-override'
import getStatusBarServiceOverride from '@codingame/monaco-vscode-view-status-bar-service-override'
import getTitleBarServiceOverride from '@codingame/monaco-vscode-view-title-bar-service-override'
import getStorageServiceOverride from '@codingame/monaco-vscode-storage-service-override'
import getLifecycleServiceOverride from '@codingame/monaco-vscode-lifecycle-service-override'
import getEnvironmentServiceOverride from '@codingame/monaco-vscode-environment-service-override'
import getWorkspaceTrustOverride from '@codingame/monaco-vscode-workspace-trust-service-override'
import getWorkingCopyServiceOverride from '@codingame/monaco-vscode-working-copy-service-override'
import getMarkersServiceOverride from '@codingame/monaco-vscode-markers-service-override'
import getAccessibilityServiceOverride from '@codingame/monaco-vscode-accessibility-service-override'
import getPreferencesServiceOverride from '@codingame/monaco-vscode-preferences-service-override'
import getSnippetServiceOverride from '@codingame/monaco-vscode-snippets-service-override'
import getLanguageDetectionWorkerServiceOverride from '@codingame/monaco-vscode-language-detection-worker-service-override'
import getUserDataProfileServiceOverride from '@codingame/monaco-vscode-user-data-profile-service-override'
import getSecretStorageServiceOverride from '@codingame/monaco-vscode-secret-storage-service-override'
import getHostServiceOverride from '@codingame/monaco-vscode-host-service-override'

import '@codingame/monaco-vscode-theme-defaults-default-extension'

import { fileTree } from '../fs.svelte.js'

// workers keyed by label (monaco-vscode-api requests by label). new URL(...import.meta.url) is rewritten by
// the esbuild-import-meta-url vite plugin (dev) and by rollup (build).
const workerFactories = {
  editorWorkerService: () => new Worker(new URL('@codingame/monaco-vscode-editor-api/esm/vs/editor/editor.worker.js', import.meta.url), { type: 'module' }),
  extensionHostWorkerMain: () => new Worker(new URL('@codingame/monaco-vscode-api/workers/extensionHost.worker', import.meta.url), { type: 'module' }),
  TextMateWorker: () => new Worker(new URL('@codingame/monaco-vscode-textmate-service-override/worker', import.meta.url), { type: 'module' }),
  OutputLinkDetectionWorker: () => new Worker(new URL('@codingame/monaco-vscode-output-service-override/worker', import.meta.url), { type: 'module' }),
  LanguageDetectionWorker: () => new Worker(new URL('@codingame/monaco-vscode-language-detection-worker-service-override/worker', import.meta.url), { type: 'module' }),
  LocalFileSearchWorker: () => new Worker(new URL('@codingame/monaco-vscode-search-service-override/worker', import.meta.url), { type: 'module' })
}
window.MonacoEnvironment = {
  getWorker: (_moduleId, label) => (workerFactories[label] ?? workerFactories.editorWorkerService)()
}

const ROOT = '/workspace'

function seedFs() {
  const provider = new RegisteredFileSystemProvider(false)
  const walk = (nodes) => {
    for (const n of nodes) {
      if (n.type === 'file') provider.registerFile(new RegisteredMemoryFile(monaco.Uri.file(ROOT + n.path), n.content ?? ''))
      else if (n.children) walk(n.children)
    }
  }
  walk(fileTree)
  registerFileSystemOverlay(1, provider)
}

const openNewCodeEditor = async () => undefined

// register our generated color themes (B2) via the theme service — the robust path, not the --vscode-* CSS
// remap (which can't bind in manual-part mode; see ide-source-graph.work). Themes come from app.css tokens.
function jsonUrl(obj) { return URL.createObjectURL(new Blob([JSON.stringify(obj)], { type: 'application/json' })) }
function registerThemes() {
  const ext = registerExtension({
    name: 'workbooks-theme', publisher: 'workbooks', version: '1.0.0', engines: { vscode: '*' },
    contributes: {
      themes: [
        { id: 'Workbooks Dark', label: 'Workbooks Dark', uiTheme: 'vs-dark', path: './dark.json' },
        { id: 'Workbooks Light', label: 'Workbooks Light', uiTheme: 'vs', path: './light.json' }
      ]
    }
  }, ExtensionHostKind.LocalProcess)
  ext.registerFileUrl('./dark.json', jsonUrl(themes.dark))
  ext.registerFileUrl('./light.json', jsonUrl(themes.light))
  // NOTE: do not await ext.whenReady() — a declarative theme contribution needs no activation, and awaiting
  // it hangs boot. The contribution is registered synchronously above, which is all the theme service needs.
}
const themeName = () => document.documentElement.getAttribute('data-theme') === 'light' ? 'Workbooks Light' : 'Workbooks Dark'

// register the file icon theme (B3): .work -> branded sparks, file types -> colorful vscode-icons, neutral
// folder/file defaults — the same icon language as our own Files surface. Set workbench.iconTheme below.
function registerIcons() {
  const ext = registerExtension({
    name: 'workbooks-icons', publisher: 'workbooks', version: '1.0.0', engines: { vscode: '*' },
    contributes: { iconThemes: [{ id: 'workbooks-icons', label: 'Workbooks', path: './icon-theme.json' }] }
  }, ExtensionHostKind.LocalProcess)
  ext.registerFileUrl('./icon-theme.json', jsonUrl(iconTheme))
  for (const [path, content] of Object.entries(iconFiles)) {
    ext.registerFileUrl(path, URL.createObjectURL(new Blob([content], { type: 'image/svg+xml' })))
  }
}

let booting
export function bootWorkbench(container) {
  if (booting) return booting
  booting = (async () => {
    seedFs()
    registerThemes()
    registerIcons()
    await initUserConfiguration(JSON.stringify({
      'workbench.colorTheme': themeName(),
      'workbench.iconTheme': 'workbooks-icons',
      'editor.fontFamily': 'Geist Mono, ui-monospace, monospace',
      'editor.fontSize': 13,
      'editor.minimap.enabled': false,
      'workbench.startupEditor': 'none',
      // NexRail is our rail — move VS Code's view-switcher to the TOP of the sidebar so there's no second
      // left rail; keep the panel at the bottom but start it collapsed (editor primary, see closePanel below).
      'workbench.activityBar.location': 'top',
      'workbench.panel.defaultLocation': 'bottom'
    }))

    await initialize({
      ...getLogServiceOverride(),
      ...getExtensionServiceOverride(),
      ...getModelServiceOverride(),
      ...getNotificationServiceOverride(),
      ...getDialogsServiceOverride(),
      ...getConfigurationServiceOverride(),
      ...getKeybindingsServiceOverride(),
      ...getTextmateServiceOverride(),
      ...getThemeServiceOverride(),
      ...getLanguagesServiceOverride(),
      ...getViewsServiceOverride(openNewCodeEditor, undefined),
      ...getQuickAccessServiceOverride({ shouldUseGlobalPicker: (_e, isStandalone) => !isStandalone && isEditorPartVisible() }),
      ...getExplorerServiceOverride(),
      ...getFilesServiceOverride(),
      ...getStatusBarServiceOverride(),
      ...getTitleBarServiceOverride(),
      ...getBannerServiceOverride(),
      ...getStorageServiceOverride(),
      ...getLifecycleServiceOverride(),
      ...getEnvironmentServiceOverride(),
      ...getWorkspaceTrustOverride(),
      ...getWorkingCopyServiceOverride(),
      ...getOutputServiceOverride(),
      ...getTerminalServiceOverride(undefined),
      ...getSearchServiceOverride(),
      ...getMarkersServiceOverride(),
      ...getAccessibilityServiceOverride(),
      ...getPreferencesServiceOverride(),
      ...getSnippetServiceOverride(),
      ...getLanguageDetectionWorkerServiceOverride(),
      ...getUserDataProfileServiceOverride(),
      ...getSecretStorageServiceOverride(),
      ...getHostServiceOverride()
    }, container, {
      workspaceProvider: {
        trusted: true,
        async open() { return false },
        workspace: { folderUri: monaco.Uri.file(ROOT) }
      }
    }, {
      userHome: monaco.Uri.file('/')
    })

    // start with the editor primary — collapse the panel (terminal/output) so it isn't covering the editor
    try {
      const cmd = await getService(ICommandService)
      await cmd.executeCommand('workbench.action.closePanel')
    } catch (e) { console.warn('[ide] closePanel', e?.message) }

    return monaco
  })()
  return booting
}

// attach each constructed Part into our DOM cells; guard per-part so one missing part can't blank the rest
export function attachParts(els) {
  const map = [
    ['ACTIVITYBAR_PART', els.activitybar],
    ['SIDEBAR_PART', els.sidebar],
    ['EDITOR_PART', els.editor],
    ['PANEL_PART', els.panel],
    ['STATUSBAR_PART', els.statusbar]
  ]
  for (const [key, el] of map) {
    if (!el) continue
    const part = Parts[key]
    try {
      attachPart(part, el)
      el.style.display = isPartVisibile(part) ? '' : 'none'
      onPartVisibilityChange(part, (v) => { el.style.display = v ? '' : 'none' })
    } catch (e) {
      console.warn('[ide] could not attach', key, e.message)
    }
  }
}

export { monaco }
