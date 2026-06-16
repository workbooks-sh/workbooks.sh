# Workbooks Desktop — tabbed workspaces

- TARGET: web
- URL: http://localhost:5178/
- FPS: 30
- VIEWPORT: 1440x900
- VERIFY_FRAMES: 9

## 00:00 navigate [url:http://localhost:5178/] [waitUntil:networkidle]

The Workbooks Browser keeps every workspace open in tabs, like the web itself.

## 00:05 click

Open the Kanban board — it lands in its own tab up top.

- selector: `button:has-text("Kanban")`
- checkpoint: the Kanban workspace is open with a 'Kanban' tab in the tab strip at the top

## 00:10 click

Open another workspace and a second tab appears beside it.

- selector: `button:has-text("Notes")`
- checkpoint: two tabs are now visible in the tab strip — 'Kanban' and 'Notes'

## 00:15 click

Switch back instantly. Your whole working life, one window.

- selector: `[role="tab"]:has-text("Kanban"), .tab:has-text("Kanban")`

## 00:18 wait [ms:1500]

Tabs for everything you do.
