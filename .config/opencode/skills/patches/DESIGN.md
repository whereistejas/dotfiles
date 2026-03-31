# patches skill — Design Notes

This document captures the reasoning behind the `patches` skill and `gen-patch`
script so that future refactoring has full context.

## Problem

The user works across multiple copies of the same repository (different
machines, workspaces, or VMs). They need to transfer commits from a source repo
to a target repo without using `git push` — often because push is banned by
policy (see `AGENTS.md`), the repos aren't networked, or the target is on a
restricted host.

The solution: generate a self-contained bash snippet that the user can
copy-paste into a terminal inside the target repo. One paste, one Enter, commit
applied.

## Key Design Decisions

### 1. Target repo is pure git — no jj dependency

The target repo may not have jj installed. Every generated snippet uses only
`git` commands (`git rev-parse`, `git apply --index`, `git commit -F -`).
jj is only used on the **source** side and only if available — the script
auto-detects and falls back to git.

### 2. Chain-of-trust safety checks

The user was concerned about accidentally applying patches to the wrong repo or
wrong branch. The solution is a chain-of-trust model:

- **Commit 1** checks that `HEAD` matches the expected base commit SHA. This
  anchors the chain to a known-good starting point. The error message includes
  the expected base commit SHA, its subject line, and (when generated from a
  branch) the source branch name — so the user knows exactly what state the
  target repo should be in.
- **Commit N > 1** checks that `HEAD^{tree}` (the tree hash) matches the
  expected state after commit N-1 was applied. The error message explains that
  the previous patch may not have been applied or was modified after applying.

Why tree hashes instead of commit hashes for subsequent checks? Because the
newly created commits in the target repo have different git commit SHAs (new
timestamps, potentially different committer info). But the **tree hash** is
deterministic — same base tree + same diff = same resulting tree, regardless of
commit metadata. This makes tree hashes a reliable cross-repo fingerprint.

### 3. Subshell wrapping

Each per-patch snippet runs inside `( ... )` so that `set -euo pipefail` and
`exit 1` (from `_fail`) don't kill the user's terminal session. The subshell
isolates the snippet's execution environment.

In batch mode, the entire script body is additionally wrapped in an outer
`( ... )` subshell. Without this, `set -euo pipefail` would leak into the
user's interactive shell — if any safety check failed, `set -e` would kill the
terminal session, and even on success the shell would be left in strict mode
where the next typo exits the terminal.

### 4. `_applied` flag for abort instructions

The `_fail` function checks `_applied` to decide whether to show abort
instructions:

- Before `git apply`: nothing has changed, no cleanup needed.
- After `git apply` but before `git commit`: changes are staged. The abort
  instruction is `git reset --hard HEAD`.

`git apply --index` is atomic — if it fails, nothing is staged. So the only
state where cleanup is needed is between successful apply and failed commit.

### 5. Heredoc delimiter safety

The diff content or commit message could theoretically contain the heredoc
delimiter string as a line. `safe_delimiter()` checks for this and appends a
random suffix if a collision is found. In practice `JJ_PATCH_EOF` never appears
in real diffs, but the check costs nothing and prevents silent corruption.

### 6. Interactive vs batch mode

The user asked for both options:

- **Interactive (one at a time)**: Each patch is copied to clipboard via
  `pbcopy`. The user pastes it, verifies it worked, then presses Enter to get
  the next one. Good for careful, deliberate transfers.
- **Batch (all at once)**: A single script containing all patches is copied to
  clipboard. The user pastes the whole thing and all patches apply sequentially.
  Good for speed when confidence is high.

The mode prompt only appears when there are 2+ commits. For a single commit,
it goes straight to clipboard.

### 7. Branch picker

When the user runs `gen-patch branch` without a name, the script lists all
available branches/bookmarks with numbered indices. The user can type a number
or a branch name. This was requested so the agent (via the skill) can present
branch choices to the user.

### 8. VCS resolution fallback

`resolve_to_git_sha()` tries jj first, then falls back to git. This means the
user can pass jj change IDs (`xyzwvut`), jj revsets (`@-`), git SHAs, git refs
(`HEAD`, `main`), or short SHAs — all work regardless of whether jj is the
detected VCS.

### 9. Error messages with diagnostic commands

Every `_fail` call includes a description of what went wrong, why it might
have happened, and a suggested command to run for diagnosis. Each error is
prefixed with the patch label (e.g. `ERROR [1/3]:`) so the user knows
exactly which patch failed.

| Failure | What the message says | Suggested command |
|---|---|---|
| Not a git repo | "Not inside a git repository" | `cd into the target repo first` |
| HEAD mismatch | Shows actual vs expected SHA, expected commit subject, and source branch (when available) | `git log --oneline -5` |
| Tree hash mismatch | Shows actual vs expected tree hash, explains the previous patch may not have been applied or was modified | `git log --oneline -3` |
| Dirty working tree | "Working tree has uncommitted changes" | `git stash` or `git status` |
| Patch apply failed | "The diff could not be applied to the current working tree. This usually means the target files have diverged from the expected state." | `git status` |
| Commit failed | "The patch was staged but the commit could not be created. A pre-commit hook may have rejected it, or the index may be empty." | `git status` |
| Need to undo | Shown when changes were staged before the failure | `git reset --hard HEAD` |

Error output uses ANSI colors: red for ERROR, yellow for ABORT, green for OK.

### 11. Source provenance in batch header

The batch script header includes provenance metadata so the user knows what
they're applying and where it came from:

- **Full script path** — the absolute path to `gen-patch` that produced the
  snippet, so the user can find the tool if they need to re-run it.
- **Source branch** — included when generated via `gen-patch branch`. Omitted
  for `gen-patch pick` (which operates on arbitrary revisions without a branch).
- **Base commit** — the SHA (truncated to 12 chars) and subject line of the
  commit that the target repo's HEAD must match. This is the parent of the
  first patch in the series.
- **Generated timestamp** — UTC ISO-8601 for auditability.

### 10. Commit messages preserved via heredoc

Multi-line commit messages are applied using `git commit -F - <<'DELIM'` which
reads the message from a heredoc. The single-quoted delimiter prevents any shell
expansion of the message content. This is safer than `-m` which would require
escaping quotes and special characters.

## Limitations

- **Merge commits** are not supported. `jj diff --git` and `git diff-tree`
  produce combined diffs for merges that `git apply` cannot handle.
- **Binary files** work via git-format diffs but the clipboard content can be
  large.
- **pbcopy** is macOS-specific. To support Linux, swap for `xclip -selection
  clipboard` or `xsel --clipboard`.
- **Non-colocated jj repos**: The script tries `jj git root` to find the
  underlying git directory, but this path is less tested than the colocated
  case.

## File Structure

```
~/.config/opencode/skills/patches/
  SKILL.md        — OpenCode skill definition (frontmatter + usage docs)
  DESIGN.md       — This file
  bin/
    gen-patch     — The bash script (executable)
```

## Frontmatter

The SKILL.md uses OpenCode's frontmatter format (not Claude's). Only these
fields are recognized: `name`, `description`, `license`, `compatibility`,
`metadata`. See https://opencode.ai/docs/skills/#write-frontmatter.
