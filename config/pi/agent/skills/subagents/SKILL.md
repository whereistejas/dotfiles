---
name: subagents
description: Hand off work to faster models by running `pi -p` subagents, in parallel when subtasks are independent. Use once a plan exists and the remaining work is implementation (writing code to a spec) or mechanical jj/VCS actions (`jj commit`, describe, split, bookmarks). Don't use for planning, design, debugging an unknown cause, or when you are already a subagent.
---

# Subagents

You plan and review; faster models do the work. A subagent is a plain `pi -p`
process running in the current directory.

## Routing

| Task type | Examples | Model |
|---|---|---|
| `code` | implement a planned change, write tests, port a module | `anthropic/claude-sonnet-5-5` |
| `ops` | `jj commit`/`describe`/`split`/`bookmark`, renames, formatting, boilerplate | `anthropic/claude-haiku-4-5` |
| `reasoning` | planning, design, root-causing, review | don't hand off — do it yourself |

## Running

Write each task to `/tmp/<name>.task`, then:

```bash
pi -p --model anthropic/claude-sonnet-5-5 "$(cat /tmp/<name>.task)" > /tmp/<name>.log 2>&1
```

Parallel (independent subtasks only, up to 5) — one bash call, no timeout:

```bash
pi -p --model anthropic/claude-sonnet-5-5 "$(cat /tmp/a.task)" > /tmp/a.log 2>&1 &
pi -p --model anthropic/claude-sonnet-5-5 "$(cat /tmp/b.task)" > /tmp/b.log 2>&1 &
wait
```

Parallel subagents share the working copy, so:

- Give each one a disjoint set of files.
- Only `code` subagents run in parallel, and they must not run `jj` write
  commands. Commit afterwards with a single `ops` subagent (or yourself).

## Task file

A subagent can't ask follow-ups. Each task must state:

- The exact files (or revisions, for `ops`) it may touch, as repo-relative paths.
- Concrete instructions — the plan, not a goal.
- How to check it's done (tests to run, expected `jj log` output).
- Prohibitions: no `jj git push`, no edits outside its files, no spawning
  subagents.

## After

Read each log, then review the result yourself (`jj diff`, `jj log`) before
reporting back.
