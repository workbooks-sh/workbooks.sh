
# Isolation tiers & trust

> How #+TRUST drives the tier a toolkit runs at — automatically.

A toolkit declares a trust posture; the host turns it into a containment tier. You
never request your own isolation — it's assigned, and only ever tightened.

```org
#+TRUST: first-party     # yours — runs at the shape's natural tier
#+TRUST: third-party     # untrusted — escalated to a separate VM automatically
```

| trust | a command runs at | a kernel runs at |
| --- | --- | --- |
| first-party | os_process | instance / node |
| third-party | node (a peer VM) | node |

A deployer can pin a truly hostile toolkit to a `container` — network-less,
resource-capped, read-only. Every tier carries memory, CPU, and wall-clock leashes;
the process and container tiers add a hard kill.

The point: more untrusted means more contained, decided above the toolkit, never
by it. See [isolation tiers](../concepts/isolation.md) for the boundaries themselves.
