# collaborative workspaces — production validation (Tier 2, EXECUTION)

> Each case validates a USER-FACING GUARANTEE of the collaborative-workspaces
> features (History/Restore/Undo/Drafts/Shared folders/RBAC) by making the
> agent ACTUALLY DRIVE the live runtime endpoints and report the observed
> result — never from memory. The judge scores the guarantee, not prose.
> Runtime base = $WB_RUNTIME (default http://localhost:4000); dev tenant via
> the `x-tenant` header. These are the continuous prod regression checks for
> the adversarial guarantees the unit/HTTP suites pin offline.

## restore brings back an old version AND loses nothing

- **TASK:** A workbook's homepage was changed and the change was a mistake. Using the runtime's History, restore the version from BEFORE that change, then confirm two things by actually checking: (1) the old content is the current version again, and (2) the History still lists every prior version — nothing was deleted.
- **RUBRIC:** EXECUTION eval. PASS only if the tool trace shows the agent ACTUALLY called the history + restore endpoints (GET /api/history/:scope, POST /api/history/:scope/restore) — not reasoning from memory — AND verifies BOTH: the restored content is live, and the timeline GREW (the restore is a new entry; the originals remain). FAIL if it claims success without re-reading the timeline, or if it describes a destructive reset.
- **EXEC:** true

## undo reverts exactly the last change

- **TASK:** An agent just made one edit to a workbook that the user wants undone. Use the runtime's Undo to revert that single most-recent change, then verify the content matches the state from before that edit — and that you can still undo again (it's reversible).
- **RUBRIC:** EXECUTION eval. PASS only if the agent actually POSTs /api/history/:scope/undo and confirms, by re-reading the content/timeline, that the last change was reverted and a NEW entry recorded the undo (append-only). FAIL on a memory-only answer or any claim that history was rewritten/erased.
- **EXEC:** true

## a shared folder copies ONLY that folder

- **TASK:** Another workspace shared a folder with you. Add it to your workspace, then verify by listing your files that EXACTLY that folder's contents arrived — and that nothing else from the other workspace (its other folders, its root files) came with it.
- **RUBRIC:** EXECUTION eval. PASS only if the agent actually calls the shared-folders endpoints (GET /api/shared-folders, POST /api/shared-folders/:id/add) AND inspects the resulting file set to confirm ONLY the shared folder's files are present — no sibling folder, no root file. FAIL if it asserts confinement without listing the files, or if any out-of-folder file is present and the agent misses it.
- **EXEC:** true

## a non-admin cannot share an org folder

- **TASK:** Acting as a workspace MEMBER (not an admin or owner), attempt to share one of the workspace's folders with someone else. Report what the runtime does.
- **RUBRIC:** EXECUTION eval. PASS only if the agent actually attempts the share via POST /api/shared-folders/share as a member-role caller AND reports that the runtime REFUSED it (HTTP 403 / forbidden) — the :share capability is admin+. FAIL if the agent reports success, doesn't actually attempt it, or invents a different reason.
- **EXEC:** true

## a Draft leaves the live version untouched until Keep

- **TASK:** Start a Draft of a workspace, make an edit inside the Draft, and confirm — by checking the live version — that the live content is UNCHANGED while the Draft holds the edit. Then Keep the Draft and confirm the live version now reflects the change and the Draft is gone.
- **RUBRIC:** EXECUTION eval. PASS only if the agent actually drives the draft endpoints (POST /api/nexuses/:id/drafts, …/keep) AND verifies the live-unchanged-then-updated transition by reading the live content at both points. FAIL on a memory-only narration or if it doesn't check the live version before Keep.
- **EXEC:** true
