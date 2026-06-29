<script>
  // Files '+' import — bring a directory in as a workspace subtree of the monorepo.
  //
  // Two paths, both landing the result as a declared workspace (id == on-disk folder path == git
  // remote /git/<id>.git == dashboard tree key — never drift them):
  //   1. LOCAL DIRECTORY — pick a folder (webkitdirectory); we package its files and, if it carries a
  //      .git, mark it for two-way sync to the workspace's git remote so the nexus can pull/push.
  //   2. GITHUB REPO — a connected-account repo (private visible) or a public URL; tracked as the
  //      subtree and kept in sync.
  //
  // In this demo the packaging/clone is mocked: we read the picked files (or parse the repo URL) and
  // register a new workspace folder so the flow + invariant are demonstrable end to end. The real
  // backend reuses Nexus.Migrate (wrap-vs-rewrite report) + the git-tenant model.
  import { importLocalDirectory, importGithubRepo } from './fs.svelte.js'
  import { ui } from './data.svelte.js'

  let { onClose } = $props()
  let mode = $state(null) // null | 'github'
  let repoUrl = $state('')
  let dirInput
  let busy = $state(false)
  let note = $state('')
  let done = $state(null) // the imported workspace { id } once it lands — drives the "Open workspace" CTA

  // on success, surface the new subtree in Studio so the CTA jumps there instead of dismissing into nowhere.
  function landed(res, msg) { note = msg; done = res; ui.section = 'studio' }

  async function onPick(e) {
    const files = [...(e.target.files || [])]
    if (!files.length) return
    busy = true
    const hasGit = files.some((f) => (f.webkitRelativePath || '').includes('/.git/'))
    const root = (files[0].webkitRelativePath || files[0].name).split('/')[0] || 'imported'
    const res = importLocalDirectory(root, files, hasGit)
    landed(res, `Imported ${res.fileCount} files as workspace “${res.id}”${hasGit ? ' · git sync armed' : ''}.`)
    busy = false
  }

  function importRepo() {
    const url = repoUrl.trim()
    if (!url) return
    busy = true
    const res = importGithubRepo(url)
    if (res.ok) landed(res, `Tracking ${res.id} as a workspace subtree · synced from GitHub.`)
    else note = 'Enter a GitHub repo URL or owner/repo.'
    busy = false
  }
</script>

<div class="fixed inset-0 z-50 flex items-start justify-center pt-[16vh] bg-[color-mix(in_srgb,var(--color-ink)_22%,transparent)] backdrop-blur-sm"
  role="button" tabindex="-1" onclick={(e) => e.target === e.currentTarget && onClose()}>
  <div class="w-[min(480px,92vw)] rounded-2xl border border-line bg-paper shadow-2xl overflow-hidden">
    <div class="px-5 pt-4 pb-3 border-b border-line">
      <div class="font-display font-semibold text-[16px]">Add files</div>
      <div class="text-dim text-[12.5px] mt-0.5">Bring a directory in as a workspace — a subtree of the monorepo, git-synced.</div>
    </div>

    {#if note}
      <div class="px-5 py-5 flex flex-col gap-4">
        <div class="text-[13.5px] text-ink">{note}</div>
        {#if done}
          <div class="flex justify-end">
            <button onclick={onClose}
              class="flex items-center gap-2 px-3.5 py-2 text-[13px] rounded-lg bg-ink text-paper hover:opacity-90 [&>svg]:w-[15px] [&>svg]:h-[15px]">
              Open workspace
            </button>
          </div>
        {/if}
      </div>
    {:else if mode === 'github'}
      <div class="px-5 py-4 flex flex-col gap-3">
        <input bind:value={repoUrl} placeholder="github.com/owner/repo  or  owner/repo"
          class="bg-card border border-line rounded-xl px-3.5 py-2.5 text-[14px] focus:outline-none focus:border-[color-mix(in_srgb,var(--color-sky)_55%,var(--color-line))]" />
        <div class="text-[12px] text-dim">Connected account → private repos are available. A public URL works without linking.</div>
        <div class="flex gap-2 justify-end">
          <button onclick={() => (mode = null)} class="px-3 py-1.5 text-[13px] text-dim hover:text-ink rounded-lg">Back</button>
          <button onclick={importRepo} disabled={busy}
            class="px-3.5 py-1.5 text-[13px] rounded-lg bg-ink text-paper hover:opacity-90 disabled:opacity-50">Track repo</button>
        </div>
      </div>
    {:else}
      <div class="p-2.5">
        <button onclick={() => dirInput.click()}
          class="w-full flex items-start gap-3 px-3.5 py-3 rounded-xl hover:bg-[color-mix(in_srgb,var(--color-ink)_6%,transparent)] text-left">
          <span class="text-[18px]">📁</span>
          <span>
            <span class="block text-[14px] text-ink">Import a local directory</span>
            <span class="block text-[12px] text-dim">Package the folder into a workspace. Git history (if any) syncs two-way.</span>
          </span>
        </button>
        <button onclick={() => (mode = 'github')}
          class="w-full flex items-start gap-3 px-3.5 py-3 rounded-xl hover:bg-[color-mix(in_srgb,var(--color-ink)_6%,transparent)] text-left">
          <span class="text-[18px]">🐙</span>
          <span>
            <span class="block text-[14px] text-ink">Import from GitHub</span>
            <span class="block text-[12px] text-dim">A repo from your connected account, or any public repo URL.</span>
          </span>
        </button>
      </div>
    {/if}
  </div>
</div>

<!-- webkitdirectory lets the picker select a whole folder; we read the file list to package it -->
<input bind:this={dirInput} type="file" webkitdirectory multiple class="hidden" onchange={onPick} />
