# workbooks-cli — agent knows the declarative flow (Tier 2)

## the agent explains scaffold → validate → apply

- **TASK:** Answer in words only — do NOT run any command. A user wants to deploy a Workbooks runtime to Fly. Using this toolkit, what is the correct ordered sequence of `wb deploy` verbs, what file is the source of truth, and which verb must you run BEFORE applying?
- **RUBRIC:** The answer follows the declarative flow: `wb deploy init [fly]` scaffolds ./deployment.md (the source of truth), the user edits it, then `wb deploy validate` (the must-run-before-apply coherence check), then `wb deploy apply` to reconcile. Bonus if it mentions status/verify/logs/down to operate it after. It must put validate BEFORE apply.
