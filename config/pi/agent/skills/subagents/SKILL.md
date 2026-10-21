---
name: subagents
description: Hand off work to faster models by running `pi -p` subagents, in parallel when subtasks are independent. Use once a plan exists and the remaining work is implementation (writing code to a spec), read-only research (scouting a large codebase or docs), or mechanical jj/VCS actions (`jj commit`, describe, split, bookmarks). Don't use for planning, design, debugging an unknown cause, when you are already a subagent, or for one long task the user wants in the background — use the `branch` tool for that.
---

# Subagents

You plan and review; faster models do the work. A subagent is a plain `pi -p`
process running in the current directory, starting with no context but its task.

A `pi -p` run blocks the conversation until it finishes. For a single task that
should run in the background with this conversation's context and report back,
use the `branch` tool instead. This skill is for fanning out self-contained tasks.

## Routing

| Task type | Examples | Model |
|---|---|---|
| `code` | implement a planned change, write tests, port a module | `anthropic/claude-sonnet-5-5` |
| `research` | read-only scouting of a large codebase or docs | `anthropic/claude-sonnet-5-5:medium` with `--tools read,grep,find,ls` |
| `ops` | `jj commit`/`describe`/`split`/`bookmark`, renames, formatting, boilerplate | `anthropic/claude-haiku-4-5` |
| `reasoning` | planning, design, root-causing, review | don't hand off — do it yourself |

- Context windows: haiku-4-5 has 200K tokens, sonnet-5-5 has 1M. A subagent that
  must read a lot shouldn't get haiku.
- Append `:<thinking>` (`low`, `medium`, `high`) to a model to set its thinking level.
- `--tools` restricts what a subagent can call, so read-only is enforced, not just
  requested.

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

Parallel subagents share the working copy, so keep one writer per set of files:

- Give each one a disjoint set of files. When the work can't be split cleanly by
  file, give each writer its own jj workspace (below).
- Only `code` and `research` subagents run in parallel, and they must not run `jj`
  write commands. Commit afterwards with a single `ops` subagent (or yourself).

## Own workspace

Create it with `agent-workspace`, not raw `jj workspace add`. In a Rust project it
starts the workspace from a clone of this one's `target/` and runs a warm-up build in
the background, so the subagent researches and edits while the build catches up
instead of waiting minutes on a cold one:

```bash
agent-workspace add <name> > /tmp/<name>.ws    # dir=<path>, and brief=<line> in Rust
```

Put the `brief=` line into the task file verbatim. Run the subagent from the
workspace:

```bash
(cd <dir> && pi -p --model anthropic/claude-sonnet-5-5 "$(cat /tmp/<name>.task)") > /tmp/<name>.log 2>&1
```

The `jj-subagent-workspaces` skill covers the brief's jj ground rules and how to
integrate the commits afterwards; replace its cleanup step with
`agent-workspace remove <dir>` (below).

## Task file

A subagent can't ask follow-ups. Each task must state:

- The exact files (or revisions, for `ops`) it may touch, as repo-relative paths.
- Concrete instructions — the plan, not a goal.
- How to check it's done (tests to run, expected `jj log` output).
- Prohibitions: no `jj git push` or other writes to remote services, no edits
  outside its files, no spawning subagents.
- In its own workspace: the workspace's absolute path, the `brief=` line, and "don't
  remove this workspace".
- Behaviour: "Use your tools; never print tool calls or patches as text. Don't end
  with a question: if you're blocked, say what decision you need."
- The output it must end with:
  - `code`/`ops`: a handoff — result, files and jj change ids touched, test state,
    open questions.
  - `research`: a Markdown report of at most N lines, organised by the questions
    asked, with `file:line` references and a yes/no/maybe verdict per finding.

## After

Read each log, then review the result yourself (`jj diff`, `jj log`) before
reporting back.

Once a workspace's commits are integrated (or dropped), run
`agent-workspace remove <dir>`. It stops the warm-up build, forgets the workspace
(snapshotting any uncommitted edits into its commit, which stays in the repo) and
deletes the folder.
