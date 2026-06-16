
# The build plan

> How the runtime turns a workbook's source blocks into a runnable artifact.

On a workbook read, the OQL kernel parses the Org into a headline tree and emits a
**build plan**: a JSON DAG of WASM worlds and components. The runtime compiles each
source block to WASM — in the sandbox — wires them together per the plan, and
renders the result.

No build pipeline to configure. The plan is derived from the document; the document
is the source of truth. The same kernel that renders your workbook renders this
docs site.

- Author the document: [Anatomy of a workbook](anatomy.md)
- Ship the result: [Publish](publish.md)
