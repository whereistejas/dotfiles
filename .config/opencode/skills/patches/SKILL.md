---
name: patches
description: Generate pasteable git-apply shell snippets from commits on a branch, with chain-of-trust safety checks between source and target repositories
license: MIT
compatibility: opencode
metadata:
  vcs: jj-or-git
  platform: macos
---

Generate self-contained bash snippets from commits that can be pasted into a
target git repository to replay them. Each snippet includes safety checks and
clear error messages with abort instructions.

The `gen-patch` CLI tool is at `~/.config/opencode/skills/patches/bin/gen-patch`.

## Commands

```bash
gen-patch pick <rev> [<rev> ...]    # specific commits (git SHAs or jj change IDs)
gen-patch branch [<name>]           # all commits on a branch since trunk/main
gen-patch -R <repo-path> <command>  # operate on a different repo
```

## Workflow

1. Identify commits the user wants to transfer (specific revisions or a branch name)
2. Run `gen-patch pick <revs>` or `gen-patch branch [name]`
   - If using `branch` without a name, the tool lists available branches for the user to pick from
   - The tool shows a summary of commits and asks the user how they want the output:
     - **One at a time** — each patch is copied to clipboard individually; user presses Enter to advance
     - **All at once** — a single self-contained script with all patches is copied to clipboard
3. The user pastes the snippet(s) into a terminal inside the target git repo

## Safety checks

Each generated snippet runs inside a subshell and includes:

- **Git repo check** — verifies the target is a git repository
- **Base commit check** (first patch) — verifies HEAD matches the expected base commit SHA
- **Tree hash check** (subsequent patches) — verifies the tree hash matches the expected state after the previous patch
- **Clean tree check** — verifies no uncommitted changes exist
- **Apply check** — catches patch application failures
- **Commit check** — catches commit failures

On failure, the snippet prints a red ERROR with a description and suggested diagnostic commands. If changes were already staged, it also prints a yellow ABORT with the command to undo (`git reset --hard HEAD`).

## VCS detection

The tool auto-detects the source repository type:
- If `jj` is available and the directory is a jj repo, it uses jj for resolving revisions and extracting diffs
- Otherwise it falls back to pure git
- All output identifiers are git commit SHAs regardless of the source VCS
- The target repo only needs git (no jj dependency)

## Notes

- The generated snippets use `git apply --index` which is atomic — if application fails, nothing is changed
- Multi-line commit messages are preserved via `git commit -F -` with heredocs
- Heredoc delimiters are checked for collisions with patch/message content
- Merge commits are not supported (the diff would be a combined diff that `git apply` cannot handle)

The user asked: $ARGUMENTS
