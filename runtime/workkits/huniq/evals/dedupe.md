# huniq — agent knows order-preserving dedupe (Tier 2)

## the agent explains huniq vs sort -u

- **TASK:** Answer in words only — do not run anything. A user has a list with duplicate lines and wants duplicates removed WITHOUT reordering the remaining lines. Which is correct: `sort -u` or `huniq`, and why?
- **RUBRIC:** The answer chooses `huniq` and explains that it removes duplicates while PRESERVING first-seen order, whereas `sort -u` reorders (sorts) the lines.
