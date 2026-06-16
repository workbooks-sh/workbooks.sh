# workbooks-browser — tab-control

# Open, focus, and close tabs in the connected shell

  Tabs in the Workbooks browser are addressed by *path* — the same path
  the file or surface has in the workspace (e.g. `README.org`,
  `notes/plan.org`). Three verbs:

  : work app open-tab  <path>    ;; open the path (or focus it if already open)
  : work app focus-tab <path>    ;; bring an already-open tab to the front
  : work app close-tab <path>    ;; close the tab for that path

# Recipes

  Open a file the user just asked about:

  : work app status               ;; confirm a shell is listening
  : work app open-tab docs/architecture.org

  Each command reports what it did and how many shells it reached:

  ;; → "open tab → docs/architecture.org (1 shell)"
  ;; → "(no desktop shell connected — nothing to open)"

# Notes

  - `open-tab` is idempotent: opening a path that's already open just
    focuses it, so you don't need to check first.
  - Paths are workspace-relative. Don't pass absolute OS paths.
  - There is no "list tabs" verb yet — track what you've opened in the
    conversation, or ask the user.
