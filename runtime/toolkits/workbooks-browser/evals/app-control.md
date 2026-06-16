# workbooks-browser — app-control verbs (Tier 2)

## the agent knows the bookmark + workspace + theme verbs

- **TASK:** Documentation question — do not call any tool. The user asks you to (a) bookmark the file notes/plan.html and (b) create a workspace called "Acme". Which two `wb app` commands cover this?
- **RUBRIC:** The answer gives `wb app bookmark notes/plan.html` (title optional) and `wb app workspace Acme` (icon optional). Both must use the `wb app` prefix with the correct sub-verb; it must NOT invent verbs like `wb bookmark` or `wb create-workspace`.
