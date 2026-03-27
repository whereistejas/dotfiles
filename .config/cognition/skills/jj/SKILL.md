---
name: jj
description: Use Jujutsu (jj) for version control instead of git
triggers:
  - user
  - model
---

# Jujutsu (jj) Version Control

You MUST use **Jujutsu (`jj`)** instead of `git` for all version control operations. Jujutsu is a Git-compatible VCS with a simpler mental model. The underlying repo is still Git, but all interactions go through `jj`.

## Core Concepts

- There is no staging area / index. Every working-copy change is automatically recorded in the current "working-copy commit."
- `jj new` creates a new empty commit on top of the current one (similar to finishing work on the current commit and starting fresh).
- `jj describe` sets the commit message (equivalent to `git commit --amend` for the message).
- Commits are identified by **change IDs** (stable across rebases) and **commit IDs** (content hashes). Prefer change IDs.

## Command Mapping (git -> jj)

| Git command | Jujutsu equivalent | Notes |
|---|---|---|
| `git status` | `jj status` or `jj st` | |
| `git diff` | `jj diff` | |
| `git diff --staged` | N/A | No staging area in jj |
| `git add . && git commit` | `jj new` | Current working-copy commit already has your changes; `jj new` finalizes it |
| `git commit --amend` | `jj describe` / `jj squash` | `describe` edits message, `squash` folds into parent |
| `git log` | `jj log` | |
| `git branch` | `jj bookmark list` | Branches are called "bookmarks" in jj |
| `git checkout -b <name>` | `jj bookmark create <name>` | |
| `git push` | `jj git push` | |
| `git pull` | `jj git fetch` then `jj rebase -d main` | Fetch + rebase is the standard workflow |
| `git rebase -i` | `jj rebase` / `jj squash` | Non-interactive by default; use multiple commands |
| `git stash` | Not needed | Just `jj new` to start new work; old commit is still there |
| `git worktree` | `jj workspace` | See Workspaces section below |
| `git merge` | `jj new A B` | Creates a merge commit with parents A and B |

## Workspaces (`jj workspace` replaces `git worktree`)

Use `jj workspace` to work on multiple changes simultaneously in separate directories:

```bash
# Create a new workspace (like git worktree add)
jj workspace add ../my-feature

# List workspaces
jj workspace list

# Remove a workspace (from within main workspace)
jj workspace forget <workspace-name>
```

Each workspace has its own working-copy commit but shares the same repo history. This is the preferred way to work on multiple features in parallel.

### Workspace Workflow Example

```bash
# From the main workspace, create a workspace for a feature
jj workspace add ../feature-auth

# In the new workspace directory, you're on a new empty commit
cd ../feature-auth
jj new main  # base your work on main
jj bookmark create feature/auth

# Make changes, then describe
jj describe -m "feat(auth): add JWT token validation"

# Push from any workspace
jj git push --bookmark feature/auth
```

## Commit Message Format (Conventional Commits)

ALL commits MUST follow the **Conventional Commits** specification:

```
<type>(<scope>): <description>

[optional body]

[optional footer(s)]
```

### Types
- `feat` - A new feature
- `fix` - A bug fix
- `docs` - Documentation only changes
- `style` - Formatting, missing semicolons, etc. (no code change)
- `refactor` - Code change that neither fixes a bug nor adds a feature
- `perf` - Performance improvement
- `test` - Adding or correcting tests
- `build` - Changes to build system or dependencies
- `ci` - CI configuration changes
- `chore` - Other changes that don't modify src or test files

### Examples

```bash
jj describe -m "feat(sdlc): add branch protection checks"
jj describe -m "fix(shell): handle timeout on WMP connection"
jj describe -m "refactor(httpServer): extract route handlers to separate modules"
jj describe -m "docs(readme): update setup instructions for Node 20"
```

## Co-Authorship

When Devin makes or contributes to a commit, ALWAYS include the co-authorship trailer:

```bash
jj describe -m "$(cat <<'EOF'
feat(scope): description of the change

Optional body explaining the motivation and context.

Co-Authored-By: Devin <noreply@cognition.ai>
EOF
)"
```

Every commit Devin creates or modifies must include the `Co-Authored-By: Devin <noreply@cognition.ai>` footer.

## Common Workflows

### Starting new work
```bash
jj new main                    # start from main
jj bookmark create feat/name   # create a bookmark
# ... make changes ...
jj describe -m "feat(scope): description

Co-Authored-By: Devin <noreply@cognition.ai>"
```

### Updating from upstream
```bash
jj git fetch
jj rebase -d main
```

### Splitting a large change
```bash
jj split           # interactively split the current commit into two
```

### Viewing history
```bash
jj log                          # condensed log
jj log -r 'ancestors(bookmarks())' # log of all bookmarked branches
jj show <change-id>             # show a specific commit
```

### Resolving conflicts
```bash
jj rebase -d main
jj resolve            # launch merge tool if conflicts exist
```

## Important Rules

1. **Never use `git` commands directly** when `jj` is initialized in a repo (check for `.jj/` directory).
2. **Always use `jj workspace`** instead of `git worktree` for parallel work.
3. **Always use conventional commits** for commit messages.
4. **Always add the Co-Authored-By trailer** when Devin creates or modifies a commit.
5. Before committing, run `jj diff` to review changes and `jj status` to confirm the state.
