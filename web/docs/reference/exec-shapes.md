
# #+EXEC shapes

> The invocation-shape reference.

| `#+EXEC` | ABI | invoked by | builds |
| --- | --- | --- | --- |
| `command` | argv + stdin → stdout | agent, workflow | yes |
| `component` | WIT-typed, in-process | component, workflow | yes |
| `kernel` | `bytes → bytes` hot loop | the fabric | yes |
| `task` | runnable recipe | agent | no |
| `federation` | OQL data source + sync | the query layer | mixed |
| `posix` | native binary | agent, workflow | no |

Each shape in depth, with when to use it: [The six shapes](../concepts/exec-shapes.md).
