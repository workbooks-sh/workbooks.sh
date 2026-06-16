
# Federation

> Make an external system a live data source you can query.

Federation turns an external system into something a workbook can query — three
faces from one toolkit.

**Read.** `SELECT … FROM <entity>` routes to a data-source plugin. Any JSON API works
with zero code: declare it in a plugin manifest and the generic HTTP source fetches
it.

```org
#+SLOT:      data-source
#+ENTITIES:  github-issue
#+IMPL:      Workbooks.DataSource.Http
#+URL:       https://api.github.com/repos/acme/app/issues
#+ROWS_PATH: .
#+ENV_KEYS:  GITHUB_TOKEN
```

**Source.** The credential resolves through a broker — the plugin never holds the
key, and the host owns the egress.

**Sync.** An optional daemon pulls the source on an interval and mirrors its rows
into local `:task:` nodes — a resident, queryable mirror, airgapped from the agent.

Linear, Asana, GitHub, your own service — each is either the generic HTTP source
with a different URL, or a small custom query module that translates to its API.

- The shape: [The six shapes](../concepts/exec-shapes.md)
