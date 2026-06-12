# Where does a piece of knowledge belong?

Three homes. Choosing wrong either buries a task the engine should drive, or
turns durable knowledge into a task that gets "closed" and lost.

| The thing | Home | Why |
|---|---|---|
| A unit of work the workflow engine loops over, where the work IS the artifact | **In the org board** (`:TASK:` heading + state) | the engine drives the loop off the heading's state; it must live where the engine parses |
| Stable cross-run knowledge — laws, method, design tokens, search discipline | **A separate skill or board file** | it's not a task; it shouldn't be "completed" — it's read every run |
| Work that spans many files or must outlive one tenant repo | **bd / beads** | bd persists independently of any single artifact repo |

## Tests to apply

- **"Does it get done and then it's over?"** → a task (org board or bd).
- **"Is it read every run regardless of progress?"** → a skill/board file, not a
  task.
- **"Will this still matter after this artifact ships / in a different repo?"** →
  bd (platform) rather than a tenant org heading.

## Common mistake

Writing durable method into a task heading. The heading gets moved to DONE and
the method vanishes from the active surface. Durable knowledge goes in a skill
or a stable board file; only the *work* goes in the task.
