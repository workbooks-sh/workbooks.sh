
# Install

> Get the wb CLI and the runtime.

The `wb` CLI is the one tool you need to author, build, run, and ship toolkits and
workbooks. It folds the whole runtime into a single binary.

```bash
curl -fsSL https://workbooks.sh/install.sh | sh
wb --help
```

The compiler toolchains live **inside** the runtime as WASM — there is nothing else
to install. Your first build provisions what it needs on demand.

- Next: [Your first toolkit](first-toolkit.md)
- Run a workbook locally: [Publish](../workbooks/publish.md)
