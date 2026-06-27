// Reactive VCS state — the branch the workspace is pointed at. Branches double as ENVIRONMENTS (the deploy
// target / "which server"): production · main · the working branch. Reactive so the footer's branch switcher
// updates live. In the runtime provider this is backed by real git over the workspace's /git/<id>.git tenant.
const state = $state({ branch: 'wb-d8ac-spine', branches: ['production', 'main', 'wb-d8ac-spine'], dirty: 0 })

export const vcsState = state
export const vcs = {
  status() { return { branch: state.branch, dirty: state.dirty } },
  branches() { return state.branches },
  current() { return state.branch },
  checkout(b) { if (state.branches.includes(b)) state.branch = b },
  setDirty(n) { state.dirty = n }
}
