# workbooks-browser — agent knows to probe first (Tier 2)

## the agent explains the probe-first rule

- **TASK:** Answer in words only — do NOT run any command. According to the workbooks-browser toolkit's golden rule, what command should you run to confirm a desktop shell is connected before driving it, and what happens to a drive command when no shell is connected?
- **RUBRIC:** The answer names `wb app status` as the probe, and explains that drive commands are SAFE NO-OPS when nothing is connected (they report "no desktop shell connected" rather than erroring), so you act optimistically and report honestly.
