---
name: subagents
description: Parallelize a task across up to 5 pi subagents via the `subagents` script. Each subtask is `artifact` (produces jj commits, gets its own jj workspace) or `properties` (edits non-`@` revisions, shares cwd). Use for independent subtasks like "port 5 modules" or "reword 8 commit descriptions". Don't use for dependent subtasks, overlapping edits, work under ~5 min, or when you are already a subagent (no recursion).
---

# Subagents

## The rule

The parent interacts with subagents only through `subagents <cmd>`.
Never run raw `tmux` or `jj` against subagent state. Never read or
write `/tmp/pi-subagents/...`. If you need something the script
can't do, stop and tell the user — do not improvise.

## Script cheatsheet

```bash
subagents --help
subagents create --surface SURFACE [--model MODEL] [--base REVSET] NAME TASK_FILE
subagents list
subagents tail [-n N] [-f] NAME
subagents log NAME
subagents merge NAME
subagents delete NAME
```

The script lives at `~/.pi/agent/skills/subagents/subagents.ts` and is
not on PATH. Invoke it by absolute path, e.g.
`~/.pi/agent/skills/subagents/subagents.ts create ...`. The shebang is
`#!/usr/bin/env bun`, so bun runs it directly — no `bun run` needed.

`--base REVSET` (artifact only) forks the subagent's workspace from a
revision other than `@`. Useful when the parent's `@` has
uncommitted work the subagent shouldn't inherit. REVSET must resolve
to exactly one revision.

## Workflow

### 1. Classify

For each subtask pick a **surface** and a **capability tier**.

Surface:

- `artifact` — edits files at `@`, ends with `jj describe`. Code
  *and* written documents (PLAN.md, SUMMARY.md) both count. For
  documents, the parent picks the exact repo-relative commit path
  up front.
- `properties` — `jj describe -r`, `jj split -r`, `jj bookmark` on
  non-`@` revisions only.

Capability tier:

- `mechanical` → `--model anthropic/claude-haiku-4-5`
- `local`      → `--model anthropic/claude-sonnet-4-5`
- `reasoning`  → omit `--model`

Use `provider/id` form. If two subtasks would touch the same files
(artifact) or revisions (properties), fold them into one subagent.

Show the user a `(name, surface, tier)` table and confirm before
spawning.

### 2. Write task files

One task file per subagent under `/tmp` (e.g.
`/tmp/port-redaction.task`). Each MUST contain:

- A "work in place" instruction. The subagent is already launched with
  its cwd set to its **own** sandbox: an isolated jj workspace for
  `artifact`, or the shared repo root for `properties`. The task MUST
  tell it to operate in its current working directory using
  **repo-relative paths only**, and to NEVER `cd` into — or use an
  absolute path that points at — any other clone of the repo, above all
  the orchestrator's repo root. Do NOT write the orchestrator's repo
  path into the task file: hardcoding it makes the subagent edit the
  parent's working copy instead of its sandbox (`jj describe` then lands
  the work on the orchestrator's `@`, the subagent's own workspace stays
  empty, and `subagents merge` has nothing to merge). If you need to name
  the workspace at all, it is `<parent-repo-dir>-<NAME>`, but prefer just
  saying "your current working directory."
- Ownership boundary (paths repo-relative to the cwd above):
    - artifact: exact files the subagent may edit; for documents,
      the exact repo-relative commit path.
    - properties: exact revisions or revset, plus "do not touch
      `@`; do not run `jj describe/split/new` without `-r`; do not
      create new commits."
- Concrete instructions (not goals).
- Scratch rule, verbatim: "Your scratch folder is
  `/tmp/<NAME>-scratch/` — create it with `mkdir -p` if needed and
  put all working notes, intermediate files, and drafts there. Do
  not create scratch files anywhere else in the repo or in `/tmp`.
  Do not read or write the orchestrator's state directory."
  (Substitute the real `NAME` when writing the task.)
- Commit rule:
    - artifact: "When finished, run `jj describe -m '<msg>'` and exit."
    - properties: "Do not create new commits. When finished, exit."
- Acceptance check (tests pass, file exists at path X, `jj show -r`
  shows the expected description, …).
- Prohibitions: no `git`/`jj push`, no invoking this skill, no edits
  outside the lane.

A subagent has no human to ask follow-ups. Ambiguity is the single
biggest failure mode.

### 3. Spawn (≤ 5)

```bash
~/.pi/agent/skills/subagents/subagents.ts create --surface artifact   --model anthropic/claude-sonnet-4-5 port-redaction /tmp/port-redaction.task
~/.pi/agent/skills/subagents/subagents.ts create --surface properties --model anthropic/claude-haiku-4-5  reword-abc     /tmp/reword-abc.task
```

Show the user each spawn's output.

### 4. Poll every 30s

```bash
subagents list
subagents tail NAME         # snapshot of recent output
subagents tail -f NAME      # follow live until the subagent finishes
```

Repeat `list` until all show `done`.

### 5. Merge each finished subagent

```bash
subagents merge NAME
```

Refuses on non-zero exit. If it refuses: `subagents log NAME`, show
the tail to the user, then `subagents delete NAME` and re-plan.

### 6. Clean up

```bash
subagents delete NAME    # for every subagent
```

When `subagents list` is empty, show the combined result on the
parent's own repo: `jj log -r '@-::@'` (artifact) or
`jj op log -n 20` (properties).

## Failure cheatsheet

- **Merge conflict** — stop, show user, don't auto-resolve.
- **Hang** (10 min no progress in `subagents tail`) — `subagents delete`.
- **Non-zero exit** — `subagents log NAME`, show tail, re-plan or delete.
- **Op-log divergence (properties)** — capture `jj op log -n1` *before*
  spawning properties subagents; inspect after; `jj op restore` if off.
- **Subagent edited the wrong repo** (its workspace is empty / `merge`
  finds nothing, but the changes appear on the orchestrator's `@`) — the
  task file pointed it at an absolute repo path instead of its own cwd.
  The work is salvageable on the parent's `@`; fix the task file's
  "work in place" instruction (see step 2) before re-spawning.
- **Wanting raw `tmux`/`jj` on subagent state** — STOP. Tell the user.
  Script gap, not a license to improvise.
