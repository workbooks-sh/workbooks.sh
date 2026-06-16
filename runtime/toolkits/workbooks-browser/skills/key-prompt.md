# workbooks-browser — key-prompt

# Ask the user for an API key (a modal)

  When you need a key/secret you don't have — to call a service, say — ask the
  user for it. `work env request` pops a clean modal in the shell and BLOCKS until
  they answer:

  : work env request <NAME> [reason…]

  On "Save key" the value is stored in the runtime secret store BY REFERENCE —
  you get a confirmation, never the raw value (the secrets-by-reference rule).

# Recipe

  : work env request OPENAI_API_KEY to call the OpenAI image API
  ;; user sees: "Enter your OpenAI key" + your reason → Save key
  ;; → "provided — OPENAI_API_KEY is now set (51 bytes), usable by reference"

# Notes

  - Blocks until the user responds (or times out). If no shell is connected it
    says so — fall back to asking them to add it in Settings.
  - You never see the value; downstream tools that read OPENAI_API_KEY pick it up.
