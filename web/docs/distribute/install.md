
# Install & registry

> Install a toolkit by hash; verify signatures; share through the library.

Installing a toolkit is installing a workbook. The hash is the gate.

```bash
wb install my-tool.wbundle                 # verify the hash, register the commands
wb install my-tool.wbundle --sha <hash>    # pin: reject anything that doesn't match
```

A tampered bundle is rejected **before** anything is registered. For a signed
third-party toolkit, install verifies the embedded signature too — a bad signature
fails the install, never the runtime.

Distribution rides the existing workbook rails: store a toolkit-workbook in the
library, search it, fetch it by key, reference it across workbooks by DID. There's
no separate registry to run — the library **is** the registry.

- How a bundle is produced + signed: [Package & sign](package.md)
