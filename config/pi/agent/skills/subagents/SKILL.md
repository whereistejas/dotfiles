---
name: subagents
description: >-
  Hand off work to faster models as subagents — fresh `branch` sessions (`fresh: true`) that start with nothing but their brief, run as pi TUIs in hidden Neovim terminals the user can join, and report back on their own. Run them in parallel when subtasks are independent. Use once a plan exists and the remaining work is implementation (writing code to a spec), read-only research (scouting a large codebase or docs), or mechanical jj/VCS actions (`jj commit`, describe, split, bookmarks). Don't use for planning, design, debugging an unknown cause, or a task that needs this conversation's unwritten context — fork a branch (no `fresh`) for that.
---

# Subagents

You plan and review; faster models do the work. A subagent is a `branch` session
started with `fresh: true`: it has no conversation but its brief.

Like every branch, it runs as a pi TUI in a hidden Neovim terminal. The user can jump
into it from the servery session picker and type into it, and its final answer arrives
here as a message when it settles. Never run headless `pi -p` subagents: nobody can see
or join them.

```
branch({ action: "start", fresh: true, name: "<name>", model: "anthropic/claude-sonnet-5-5", task: "<brief>" })
```

`start` returns at once. Keep working or return control; never sleep or poll waiting
for the report.

Prefer a subagent over a forked branch whenever the task fits in a written brief, and
always once the conversation is long: a fork re-reads the whole conversation on every
step, which makes each turn slow and can exceed a small model's context (see
`AGENTS.md` → Workflow).

## Routing

| Task type | Examples | `model` / `tools` |
|---|---|---|
| `code` | implement a planned change, write tests, port a module | `anthropic/claude-sonnet-5-5` |
| `research` | read-only scouting of a large codebase or docs | `anthropic/claude-sonnet-5-5:medium`, `tools: ["read", "ffgrep", "fffind"]` |
| `ops` | `jj commit`/`describe`/`split`/`bookmark`, renames, formatting, boilerplate | `anthropic/claude-haiku-4-5` |
| `reasoning` | planning, design, root-causing, review | don't hand off — do it yourself |

- Context windows: haiku-4-5 has 200K tokens, sonnet-5-5 has 1M. A subagent that
  must read a lot shouldn't get haiku.
- Append `:<thinking>` (`low`, `medium`, `high`) to a model to set its thinking level.
- `tools` is an allowlist (`pi --tools`), so read-only is enforced, not just
  requested. Name every tool it needs.

## Parallel

Start up to 5 for independent subtasks, one `start` call each. Keep one writer per
working copy:

- Every subagent that edits files gets `write: true`, its own jj workspace (from
  `agent-workspace`; in a Rust project it starts warm with a background build, and
  the brief carries that build's `brief=` line automatically).
- Read-only subagents share the current working copy and need no workspace.

## Permissions

A subagent never asks for permission, so the `branch` tool enforces a policy:

- It may write only inside its jj repo, where `jj undo` reverts it.
- It may push and force-push its own branches and write GitLab/GitHub MRs (never
  `main`); other remote writes are blocked. Pass `remote: false` for a subagent
  that mustn't push.
- `subagents: true` lets it start subagents of its own; it receives their reports.

## Brief

A subagent can't see this conversation. The brief (`task`) must state:

- The exact files (or revisions, for `ops`) it may touch, as repo-relative paths.
- Concrete instructions — the plan, not a goal.
- How to check it's done (tests to run, expected `jj log` output).
- What to push (bookmark, MR target), or that it mustn't push.
- What not to do: edits outside its files.
- The output it must end with:
  - `code`/`ops`: a handoff — result, files and jj change ids touched, test state,
    open questions.
  - `research`: a Markdown report of at most N lines, organised by the questions
    asked, with `file:line` references and a yes/no/maybe verdict per finding.

The tool adds the rest itself: that nobody is watching, not to stop on a question,
to use tools rather than print them, and the workspace rules.

## Monitoring

- `branch({ action: "peek", name })`: its tool calls and latest text so far.
- `branch({ action: "steer", name, message })`: a correction or answer; it lands
  after the current tool call.
- `branch({ action: "list" })`: every branch and subagent of this session, with its
  status.

## After

Read each report, then review the result yourself (`jj diff`, `jj log`) before
reporting back. The `jj-subagent-workspaces` skill covers integrating a writer's
commits; skip its cleanup step.

Once the work is integrated (or dropped), `branch({ action: "close", name })`. It
wipes the terminal and, for a writer, stops the warm-up build, forgets the workspace
(snapshotting any uncommitted edits into its commit, which stays in the repo) and
deletes the folder.
