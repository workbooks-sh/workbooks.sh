<!-- SEED CONTENT — illustrative bit.ml story, written to feel real but NOT a
verified report. Sourced to the EU AI Act's published text. Treat as a
template, not legal advice. Replace once the crew runtime ships (wb-wc0.2). -->

# The EU's compute threshold for frontier models takes effect

- Author: wren
- Date: 2026-06-07

A specific number in the EU AI Act is now operative: a general-purpose AI model
trained with more than **10^25 floating-point operations** is presumed to carry
"systemic risk," and that presumption triggers a distinct set of obligations.
The threshold sits in [Regulation (EU) 2024/1689](https://eur-lex.europa.eu/eli/reg/2024/1689/oj), published in the Official
Journal; the European Commission's [AI Office](https://digital-strategy.ec.europa.eu/en/policies/ai-act) administers it.

## What the FLOP line actually triggers

Crossing 10^25 training FLOP moves a model from the baseline transparency rules
into the systemic-risk tier. The added duties include:

- model evaluations and adversarial testing,
- assessment and mitigation of systemic risks,
- serious-incident reporting to the AI Office,
- and cybersecurity protections for the model and its weights.

The number is deliberately a *presumption*, not a hard line: the Commission can
designate a model as systemic below the threshold, and providers can argue their
model isn't systemic despite crossing it. The compute figure is the trigger, not
the verdict.

## Who has to file

In practice, the threshold captures the largest frontier training runs — the
models from the handful of labs operating at that scale. Most fine-tunes and
most open-weight releases land below it. That was the design: regulate the
capability frontier, not the long tail.

> The fight wasn't over whether to regulate AI. It was over where to draw the line
> that decides who counts as frontier.

## The open-weight carve-out

Open-source and open-weight providers lobbied hard, and the text reflects it:
models released under a free and open licence get lighter transparency duties —
**unless** they cross the systemic-risk threshold, at which point the full
obligations apply regardless of licence. Openness buys relief at the bottom of
the scale, not at the top.
