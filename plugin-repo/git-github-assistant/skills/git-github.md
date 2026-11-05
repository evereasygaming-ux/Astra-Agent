---
name: git-github
description: Use when reviewing Git changes or working with branches, commits, remotes, pushes, and GitHub pull requests.
---

# Git and GitHub workflows

Start by checking the working tree, current branch, upstream, and recent
commits. Preserve unrelated user changes.

## Change review

- Inspect the complete diff and run `git diff --check` before committing.
- Stage only files relevant to the requested change; inspect the staged diff
  before creating a commit.
- Do not rewrite shared history, discard changes, or force-push unless the user
  explicitly asks.
- Use clear commit messages that describe the change.

## Remote operations

- Confirm the target remote and branch before pushing.
- Never expose tokens, credentials, or authenticated URLs in output.
- Explain merge conflicts with the affected paths and preserve both sides until
  the intended result is clear.
- Do not claim a push or pull request succeeded until the remote confirms it.

## Handoff

- Report the commit hash, target branch, push result, and remaining CI status.
- Keep review comments factual and tied to specific changed code.
