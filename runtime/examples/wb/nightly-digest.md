# Nightly Digest

This workflow runs every morning: it reads yesterday's events, summarizes them
with an LLM, and emails the result. Three components, three languages.

## Nightly digest (workflow)

SCHEDULED: 2026-06-06 Sat 06:00 +1d

### Fetch events (component)

```rust :uses workbook:vfs/query :out events:list
// query the Workbook VFS for yesterday's events
let events = vfs::query("SELECT * FROM events WHERE ts > now() - 1d");
```

### Summarize (component)

```js :in events:list :uses workbook:llm/complete :out summary:string
export default (events) => llm.complete("Summarize these events", events);
```

### Send (component)

```go :in summary:string :uses workbook:net/email
email.Send("me@co", "Your digest", summary)
```
