# workbooks-browser — app-control

# Theme, bookmarks, and workspaces

  Beyond tabs, you can drive these app surfaces through `work app …`. Each is a
  safe no-op when no shell is connected (probe with `work app status` first).

  : work app theme <id>              ;; switch the app theme to an existing theme id
  : work app bookmark <path> [title] ;; add a bookmark for a path (title optional)
  : work app workspace <name> [icon] ;; create a new workspace (icon optional, emoji)

# Recipes

  Bookmark the file the user is working on:

  : work app bookmark docs/architecture.org "Architecture"
  ;; → "bookmarked docs/architecture.org (1 shell)"

  Spin up a workspace for a new project:

  : work app workspace "Client X" 💼
  ;; → "workspace → Client X (1 shell)"

# Notes

  - `theme <id>` takes an EXISTING theme id (the ones in Settings → Themes), not
    a freeform name. Authoring a new theme isn't wired yet.
  - Paths are workspace-relative, like `open-tab`.
  - Every verb reports how many shells it reached; 0 means nobody's connected.
