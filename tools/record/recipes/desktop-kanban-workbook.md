# Workbooks Desktop — Kanban workbook

- TARGET: web
- URL: http://localhost:5178/
- FPS: 30
- VIEWPORT: 1440x900
- VERIFY_FRAMES: 9

## 00:00 navigate [url:http://localhost:5178/] [waitUntil:networkidle]

Click a workspace and it opens as a live workbook in its own tab.

## 00:04 click

Here's a Kanban board — backlog, in progress, and done, with real cards.

- selector: `button:has-text("Kanban")`
- checkpoint: a Kanban board titled 'Kanban Board' with three columns — Backlog, In Progress, Done — each holding cards; it is open as a browser tab

## 00:10 hover [x:830] [y:196]

It isn't a screenshot. It's running software, rendered right inside the browser.

## 00:15 screenshot [name:board-hover]

Every workbook is its own little app, side by side in tabs.

- checkpoint: the Kanban board is intact with a card highlighted; no error overlay

## 00:18 wait [ms:1500]

Real software, not slides.
