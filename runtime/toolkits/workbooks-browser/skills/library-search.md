# workbooks-browser — library-search

# Find content across the user's workbooks (recall, don't re-derive)

  The user's Library is their set of workbooks. When they ask "where did I write
  about X", "find my notes on Y", or you need to ground an answer in their own
  content, SEARCH it — don't guess.

  : wb search <words>                  ;; hybrid (meaning + literal) over the whole library
  : wb search <words> --semantic       ;; by meaning only
  : wb search <words> --literal        ;; exact text only
  : wb search <words> --workbook <id>  ;; scope to one workbook
  Each hit is `workbook/path :: headline` + a snippet — quote the path so the user
  can open it. "(no matches)" means nothing matched; say so, don't invent a result.

# See + query the structure

  : wb library                         ;; list workspaces + their members
  : wb library query "<sql>"           ;; cross-workbook SQL over members' data

# Honesty

  - This searches the user's OWN library (per-tenant); you only see their content.
  - Recall before re-deriving: if the user likely wrote it down, `wb search` first.
  - Report real hits with their paths; never fabricate a match or a path.
