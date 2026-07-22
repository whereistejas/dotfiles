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
cargo run -q --offline --manifest-path ~/.pi/agent/skills/subagents/scripts/subagents/Cargo.toml -- --help
cargo run -q --offline --manifest-path ~/.pi/agent/skills/subagents/scripts/subagents/Cargo.toml -- create --surface SURFACE [--model MODEL] [--base REVSET] NAME TASK_FILE
cargo run -q --offline --manifest-path ~/.pi/agent/skills/subagents/scripts/subagents/Cargo.toml -- list
cargo run -q --offline --manifest-path ~/.pi/agent/skills/subagents/scripts/subagents/Cargo.toml -- tail [-n N] [-f] NAME
cargo run -q --offline --manifest-path ~/.pi/agent/skills/subagents/scripts/subagents/Cargo.toml -- log NAME
cargo run -q --offline --manifest-path ~/.pi/agent/skills/subagents/scripts/subagents/Cargo.toml -- merge [--onto REVSET] [--bookmark NAME] NAME
cargo run -q --offline --manifest-path ~/.pi/agent/skills/subagents/scripts/subagents/Cargo.toml -- delete NAME
```

The CLI is a Rust binary crate at
`~/.pi/agent/skills/subagents/scripts/subagents`. Invoke it with `cargo
run`, pointing `--manifest-path` at that crate so it runs from your
current directory (the tool shells out to `jj` in your cwd, and `cargo
run` leaves the cwd unchanged). The first run builds it; later runs are a
fast freshness check.

```bash
cargo run -q --offline \
  --manifest-path ~/.pi/agent/skills/subagents/scripts/subagents/Cargo.toml \
  -- <SUBCOMMAND> [ARGS...]
```

Every example below is that same `cargo run … --` line with the
subcommand and args after `--`. Runtime deps: `cargo`, `jj`, and `pi` on
PATH, plus `bun` (used only to launch pi).

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
cargo run -q --offline --manifest-path ~/.pi/agent/skills/subagents/scripts/subagents/Cargo.toml -- create --surface artifact   --model anthropic/claude-sonnet-4-5 port-redaction /tmp/port-redaction.task
cargo run -q --offline --manifest-path ~/.pi/agent/skills/subagents/scripts/subagents/Cargo.toml -- create --surface properties --model anthropic/claude-haiku-4-5  reword-abc     /tmp/reword-abc.task
```

Show the user each spawn's output.

### 4. Poll every 30s

```bash
cargo run -q --offline --manifest-path ~/.pi/agent/skills/subagents/scripts/subagents/Cargo.toml -- list
cargo run -q --offline --manifest-path ~/.pi/agent/skills/subagents/scripts/subagents/Cargo.toml -- tail NAME         # snapshot of recent output
cargo run -q --offline --manifest-path ~/.pi/agent/skills/subagents/scripts/subagents/Cargo.toml -- tail -f NAME      # follow live until the subagent finishes
```

Repeat `list` until all show `done`.

`list` derives health from each subagent's live pi transcript (the `-p`
log only flushes on exit, so it's useless mid-run). The `STATUS` column
can read:

- `running` — transcript advancing normally; `DETAIL` shows the in-flight
  tool + how long it's run (e.g. `bash 12s`) or `idle Ns` between turns.
- `stalled` — no new transcript event for ≥ 120s (override with
  `PI_SUBAGENTS_STALL_SECS`). A long-running in-flight tool in `DETAIL`
  (e.g. `bash 900s`) means a runaway command; `idle 900s` means a wedged
  model turn. Investigate, then `subagents delete` + re-spawn if wedged.
- `errored` — the last model turn failed (API timeout, auth, etc.);
  `DETAIL` shows the error. Don't poll forever — delete and re-plan.
- `done` / `crashed` — as before.

`tail`/`tail -f` fall back to a readable render of the transcript while
the `-p` log is empty, so they show live progress instead of nothing;
`tail -f` stops on `done` or an errored turn.

### 5. Merge each finished subagent

```bash
cargo run -q --offline --manifest-path ~/.pi/agent/skills/subagents/scripts/subagents/Cargo.toml -- merge NAME                              # rebase onto @ (default)
cargo run -q --offline --manifest-path ~/.pi/agent/skills/subagents/scripts/subagents/Cargo.toml -- merge --onto REVSET NAME               # land elsewhere; leaves @ put
cargo run -q --offline --manifest-path ~/.pi/agent/skills/subagents/scripts/subagents/Cargo.toml -- merge --onto REVSET --bookmark BM NAME # ...and name the tip
```

By default `merge` rebases the subagent's commit chain onto the parent's
`@` and advances the working copy onto it. `--onto REVSET` lands the chain
on another revision instead (e.g. the `dev` bookmark) and leaves the
parent's `@` untouched — use this when you forked with `--base` and want
the result to stay off `@`. `--bookmark BM` points a bookmark at the
landed tip. `merge` requires a single linear chain (one root, one head).

Refuses on non-zero exit. If it refuses: `subagents log NAME`, show
the tail to the user, then `subagents delete NAME` and re-plan.

### 6. Clean up

```bash
cargo run -q --offline --manifest-path ~/.pi/agent/skills/subagents/scripts/subagents/Cargo.toml -- delete NAME    # for every subagent
```

When `subagents list` is empty, show the combined result on the
parent's own repo: `jj log -r '@-::@'` (artifact) or
`jj op log -n 20` (properties).

## Failure cheatsheet

- **Merge conflict** — stop, show user, don't auto-resolve.
- **Hang** — `subagents list` shows `stalled` (no transcript event for
  ≥ 120s) or `errored`. Check `DETAIL`/`subagents tail`, then
  `subagents delete` and re-spawn.
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
