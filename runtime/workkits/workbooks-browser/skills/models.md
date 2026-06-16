# workbooks-browser — models

# Discover models + switch your own

  You can browse OpenRouter's whole catalog and change the model YOU run on.

  : work models list [query]   ;; search models — query matches id/name/modality
  : work model get             ;; the model you're running on now
  : work model set <id>        ;; switch to a different model (this session)

# Finding a model for a task

  Need a vision/image model? Filter by modality or vendor:

  : work models list image
  : work models list gemini
  ;; → rows: MODEL  CONTEXT  MODALITY (e.g. text+image->text)  $/Mtok-in

  Then switch to it for the work:

  : work model set google/gemini-2.5-flash-image

# Should I switch? (always TWO reads, then recommend)

  When asked whether to switch models for a task, never answer from memory — run
  BOTH commands, in order, then compare what you actually read:

  : work model get            ;; 1. the model you run on now (note its id + modality)
  : work models list <cap>    ;; 2. live candidates with the capability you need

  Only after BOTH have returned do you recommend: name a concrete model id from
  the list and say switch-or-stay (and why). One read alone is not enough — you
  must know both your current model AND the live options to make the call.

# Notes

  - The list shows id, context window, modality, and prompt price per 1M tokens.
  - `model set` applies for the rest of this session; it doesn't persist.
  - Use this when a task needs a capability your current model lacks (vision,
    cheaper bulk work, a bigger context window).
