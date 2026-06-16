# workbooks-browser — app-control

# Theme, bookmarks, and workspaces

  Beyond tabs, you can drive these app surfaces through `wb app …`. Each is a
  safe no-op when no shell is connected (probe with `wb app status` first).

  : wb app theme <id>              ;; switch the app theme to an existing theme id
  : wb app bookmark <path> [title] ;; add a bookmark for a path (title optional)
  : wb app workspace <name> [icon] ;; create a new workspace (icon optional, emoji)

# Recipes

  Bookmark the file the user is working on:

  : wb app bookmark docs/architecture.org "Architecture"
  ;; → "bookmarked docs/architecture.org (1 shell)"

  Spin up a workspace for a new project:

  : wb app workspace "Client X" 💼
  ;; → "workspace → Client X (1 shell)"

# Notes

  - `theme <id>` takes an EXISTING theme id (the ones in Settings → Themes), not
    a freeform name. Authoring a new theme isn't wired yet.
  - Paths are workspace-relative, like `open-tab`.
  - Every verb reports how many shells it reached; 0 means nobody's connected.
