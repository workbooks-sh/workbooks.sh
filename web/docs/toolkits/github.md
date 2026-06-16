
# Workbooks + GitHub

> Give a workbook's agent repo, PR, and issue operations against GitHub — through the brokered git toolkit and a host-held token.

- **MATURITY:** north-star
- **CAVEAT:** A dedicated GitHub toolkit (PR / issue / API operations) is not yet published. Local repo operations ship today via the `git` toolkit (toolkits/git/manifest.org); GitHub-API actions (open a PR, comment, manage issues) are the intended addition described here, not a shipped surface.

Connecting GitHub would let a workbook's agent do the repo work it already
reaches for — branch, commit, open a pull request, file and triage issues —
against a real GitHub repository, with the token held by the host. The local
half (everything `git` can do) ships today; the GitHub-API half is the planned
extension.

| Field | Value |
| --- | --- |
| Toolkit id | `github` (planned) · `git` (ships today) |
| #+EXEC shape | `command` |
| Backing CLI | `git` (+ `gh` / GitHub API, planned) |
| Status | `north-star` (git: `stable`) |
| Manifest | `toolkits/git/manifest.org` |

## What it does

Shipping today (via the `git` toolkit):

- Branch, commit, rebase without losing work, recover a detached HEAD, undo a
  commit safely, bisect, cherry-pick — end-to-end recipes in `toolkits/git/skills/`.

Planned (the GitHub integration proper):

- Open and update pull requests.
- File, comment on, and close issues.
- Read PR/issue state to drive an agent's plan.

## Capabilities it grants

- **MATURITY:** partial
- **EVIDENCE:** toolkits/git/manifest.org:4
- **SRC:** toolkits/git/manifest.org

| Capability | Why it needs it |
| --- | --- |
| `vfs` | Read / write the repo working tree |
| `posix` | Run the `git` binary (`git/manifest.org:4`, `CLI_BIN: git`) |
| `net` | Push / fetch; reach the GitHub API (planned) |
| `secrets` | The GitHub token the host holds (planned) |

See [Dock capabilities](../reference/caps.md).

## How to add it

- **MATURITY:** north-star
- **CAVEAT:** `wbx toolkit add github` and the host-held GitHub token are the intended ergonomics. Today you use the in-repo `git` toolkit for local operations; the GitHub-API path is not shipped.

The intended flow:

1. Set the GitHub token as a host secret (the toolkit never sees it):
```text
   wbx secret set GITHUB_TOKEN <token>
```

2. Add the toolkit:
```text
   wbx toolkit add github
```

Today, for local repo work, reference the `git` toolkit and read its skills on
demand (see the skill index in `toolkits/git/manifest.org`).

> **Caution:** The host holds `GITHUB_TOKEN` and owns egress — the toolkit asks for a GitHub action across the Dock and never sees the credential.

## Worked example

Local, shipping today — rebase a feature branch onto updated main using the
toolkit's recipe (no training-data guesswork):

```text
# agent reads toolkits/git/skills/rebase-without-losing-work
git fetch origin
git rebase origin/main
# conflicts resolved per the recipe, then:
git push --force-with-lease
```

Planned — once the GitHub integration ships, the same agent would then open a PR:

```text
wbx github pr open --base main --title "..."   # planned
```

## Related toolkits

- Workbooks + Linear — issue tracking sync (`toolkits/linear/`)
- Workbooks + Slack — notify a channel on a PR/issue event ([slack](slack.md))
- Build: [Authoring skills](../build/skills.md) (how the git recipes are structured)
- All integrations: [Toolkits & integrations](index.md)

## Maturity

`north-star` for the GitHub-API integration; the local `git` toolkit is `stable`
and ships today (`toolkits/git/manifest.org`). The honest split: an agent can do
everything local `git` does right now via that toolkit's verbatim recipes; the
GitHub-side actions (PRs, issues, API) are the documented next step, not a present
capability. No present-tense claim is made for the unbuilt half.

- Capability Matrix row: [/maturity](../maturity/index.md)
- Source of truth (shipping half): `toolkits/git/manifest.org`
