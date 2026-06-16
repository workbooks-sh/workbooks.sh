
# Authoring skills

> The progressive-disclosure recipes that teach an agent to use a toolkit.

A compiled binary tells an agent **nothing** about how to use it — what the flags
mean, the gotchas, the right recipe. That knowledge is the toolkit's **skills**:
hand-authored org files an agent reads on demand.

The manifest is a need-keyed index; each skill is read only when relevant, so an
agent spends context on the one tool it's using, not the whole catalog.

A good skill has a fixed shape: **when to use this** (and when not), *the mental
model* (why before how), a **workflow** of runnable steps, **common pitfalls** found
empirically, and a **verification checklist**. Breadth is the common surface plus the
gotchas — not an exhaustive flag dump.

```org
* When to use this
  Trigger + a "NOT for" line.
* Workflow
  Numbered, runnable steps.
* Common pitfalls
  The mistakes, why they happen, the fix.
```

- See it discovered: [Invoking a toolkit](../run/invoke.md)
