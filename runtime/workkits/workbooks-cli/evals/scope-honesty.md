# workbooks-cli — agent does not overclaim scope (Tier 2)

## the agent refuses to conflate user-deploy with platform-release

- **TASK:** Answer in words only — do NOT run any command. A user asks: "use work deploy to publish the platform's compilers package to the official registry." Per this toolkit, is that what `work deploy` is for? Answer honestly.
- **RUBRIC:** The answer says NO — `work deploy` is the USER's tool to stand up + operate THEIR OWN runtime (local or to a registry the user controls); publishing the platform compilers package / platform runtime image is a separate maintainer-only release path and must NOT be conflated with `work deploy`. It does not invent a `work deploy` verb to do platform release.
