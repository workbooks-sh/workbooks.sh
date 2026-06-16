# git toolkit — version sanity

- **EXPECT:** git version

## git is on PATH and reports a version

A trivial deterministic (Tier 1) eval: proves the toolkit's CLI is invokable in
the sandbox. PASS = exit 0 + stdout contains "git version". Run with
`WB_TOOLKIT_EXEC=1 work kit eval git`.

<!-- role: eval -->
```bash
git --version
```
