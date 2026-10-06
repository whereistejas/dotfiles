# branch — spec

Fork the current pi conversation into a second pi session that runs in a Neovim
terminal buffer, and post its result back into a conversation when it settles.
Complements the `subagents` skill, which stays for parallel fan-out.

## Goals

1. **Never block the conversation.** Delegated work, and work already in flight,
   runs in another session while the user keeps talking.
2. **Full context, no re-briefing.** A branch is a fork of the session, so it
   already knows everything the parent knew.
3. **Results come back on their own.** When a branch settles, its final answer is
   posted into its receiver session, waking the agent there if it's idle.
4. **Attach and detach, like nvim.** Every branch is a pi TUI in an nvim terminal
   buffer. Foreground means showing that buffer; background means hiding it.
5. **jj-first and safe unattended.** A branch never asks for permission. It can do
   anything `jj` can undo. It can never write to a remote service.

## Non-goals (v1)

- Running outside Neovim (`$NVIM` unset → the extension refuses with a message)
- Headless/RPC children, agent definitions, chains, parallel orchestration
- Surviving an nvim restart (buffers die with the nvim session)
- Stuck/idle detection, watchdogs, completion batching, pruned forks
- Automatic jj integration (rebasing/squashing a branch's commits)

## Terms

- **Worker**: the session doing the work, which reports when it settles.
- **Receiver**: the session that gets the report.
- **Branch**: one worker/receiver pair, with a short `name` (e.g. `scout-auth`).

## Two flows, one mechanism

### A. `branch` tool — the agent delegates up front

1. The agent calls `branch({ action: "start", name, task, model?, write? })`.
2. The extension forks the current session at the current leaf into a new file.
3. It opens a hidden nvim terminal running `pi --session <fork> <brief>`, where
   the brief is the worker preamble plus `task`.
4. The tool returns immediately: "started branch `<name>` in buffer N".
5. The current session is the **receiver**; the new pi is the **worker**.

### B. `/bg` — the user backgrounds the turn that's running

1. The user types `/bg [name]` mid-turn. Extension commands run immediately, even
   while a turn is in progress.
2. The extension forks the session **at the last user message** into a new file,
   adding a marker entry: "This request is running in background branch
   `<name>`; its result will be posted here."
3. It opens a terminal running `pi --session <fork>` **in the current window**. The
   original pi's buffer is now hidden but keeps running.
4. The **original session becomes the worker**. It gets the worker preamble as a
   steer and the background permission policy. Its turn runs to completion;
   nothing is aborted or re-run.
5. The new fork is the **receiver**, and the user carries on talking there.

## Worker behaviour

- **Preamble**, sent as the first user text (flow A) or a steer (flow B). It's
  borrowed from pi-subagents:
  - "You are a background branch of the conversation above. Treat the inherited
    conversation as reference only; your job is only the task below."
  - "Nobody is watching this terminal: don't ask for confirmation, don't end with
    a question you need answered to continue — report it instead."
  - "Finish with a handoff: result, files/changes touched (jj change ids), test
    state, open questions."
- **No nesting.** The worker sees no `branch` tool, and `/bg` is disabled inside a
  worker (env `PI_BRANCH_WORKER=1`).
- **Permission policy.** It's enforced by a `tool_call` hook, not only by the
  prompt, and blocked calls return a reason the worker can report:
  - **Reads**: allowed anywhere (files, `jj log/diff/show`, read-only CLI verbs).
  - **Local writes**: allowed only inside the jj repo's working copy, where `jj`
    can undo them (`jj op log`/`jj undo`). Writes outside the repo are blocked.
  - **Remote writes**: always blocked. This covers `ssh`/`scp`/`rsync host:`,
    `git push`/`jj git push`, write verbs of `aws`, `jira-cli`, the GitLab CLI and
    `curl`/`wget` with a method or body, and any MCP tool not marked
    `readOnlyHint`. It's a best-effort command denylist with a read-verb allowlist
    for known CLIs. Anything unclassifiable that looks remote is blocked.
- **Writers get a jj workspace** (flow A with `write: true`). The fork's cwd is
  set to a new `jj workspace add` directory, and the session header's `cwd` is
  rewritten to match. Read-only branches stay in the parent cwd. Flow B keeps its
  cwd because the process is already running.
- **Model** (flow A): inherit the parent model unless `model` is given. Only pick
  `claude-haiku-4-5` when the fork fits comfortably within 200K tokens. Flow B keeps
  its model.

## Reporting

- When a worker emits `agent_settled`, it writes its newest final assistant text
  to the receiver's inbox as one JSON file per report.
- The receiver polls its inbox. For each report it calls
  `pi.sendMessage({ customType: "branch-report", content, display: true })` and
  deletes the file only after delivery.
  - **Idle wake**: if the receiver is idle, `sendMessage(triggerTurn: false)`,
    then `sendUserMessage("Branch <name> reported.", { deliverAs: "steer" })`.
  - This keeps `before_agent_start` hooks running (pi#5581 workaround).
- `content` is a preview of at most about 4 KiB plus the worker session path, so
  the full answer stays readable on demand.
- A worker that's steered or followed up and settles again reports again. Each
  report covers only what's new since the last one.
- A report addressed to a receiver that isn't running waits in its inbox and is
  delivered on that session's next `session_start`.

## Talking to a running branch

- `branch({ action: "peek", name })`: compact view of the worker's progress so
  far (tool calls, latest text), read from its session file.
- `branch({ action: "steer", name, message })`: writes to the worker's inbox; the
  worker calls `sendUserMessage(wrapped, { deliverAs: "steer" })`, or a plain
  follow-up turn if it's idle. The wrapper says: "Mid-run steering from the
  parent: … Incorporate at the next safe point; don't restart unless asked."
- `branch({ action: "list" })` and `/branches`: name, role, status (starting/running/
  idle/exited), buffer, model, cwd.
- `/fg <name>`: show that branch's buffer in the current window. The user can
  type into it directly (native pi steering). `:b#` goes back.

## Lessons borrowed from pi-subagents

Each of these was a bug upstream (CHANGELOG refs in `/tmp/scout-pi-subagents.log`).

Forking:
- Fork from a throwaway `SessionManager.open(parentFile)`, never the live one,
  or the parent's own tool result leaks into the fork. If the returned fork file
  doesn't exist yet, write it ourselves.
- Strip signed/redacted Anthropic thinking blocks (including inside
  `context_edit` replacements). Signatures don't survive a fork; the worker keeps
  its thinking level.
- Strip the parent's own `branch` tool calls/results and `branch-report`
  messages from the fork, so the worker doesn't try to continue orchestration.
- Store forks under `<parent-session>/forks/` so `pi -c` isn't hijacked.
- Rewrite the fork's session-header `cwd` to the worker's cwd (realpath), or the
  worker resumes in the parent's directory.
- Fail closed: no persisted session or leaf, or a bad cwd → `start` fails before
  anything is forked or opened. Never silently downgrade.
- Workers are started by nvim, so they get nvim's environment, not the parent pi's.

Worker:
- Preamble as a user-text prefix: "treat the inherited conversation as reference
  only; don't answer prior messages". Forked children otherwise carry on the
  parent's conversation.
- The same brief says: "You are not the parent: don't start branches. Use your
  tools; never print tool calls or patches as text." It's in the brief rather
  than the system prompt so flow B can deliver it as a steer.

Steering:
- Wrap every steer: "Mid-run steering from the parent: … Incorporate at the next
  safe point; don't restart unless asked."
- Report a steer as `queued` when written and `delivered` only once the worker
  sees the matching user `message_end`. `peek`/`list` show which.
- A steer arriving between `agent_end` and `agent_settled` is held until settled
  and then sent as a follow-up, not fired as an early idle prompt.
- A steer doesn't interrupt an in-flight tool (e.g. a long `bash`); it lands after
  it. Say so in the tool description.

Reporting:
- Delete an inbox file only after `sendMessage` accepts it. Every report has an
  id, and delivered ids are remembered, so `/reload` can't double-send.
- Idle wake = `sendMessage(triggerTurn: false)` + `sendUserMessage(…, steer)`, so
  `before_agent_start` hooks still run. Pending-wake state lives on `globalThis`
  (survives `/reload`) and expires after 10 s.
- Poll inboxes (about 1 s); don't use `fs.watch`, which hung reloads on macOS.
- Preview at most about 4 KiB, cut on a UTF-8 boundary, plus the session path.
- If the worker's terminal exits before it reports, report that as a failure
  with the last lines of the buffer.

Parent guidance (the `branch` tool description):
- Branch only when the user asks, directly or through instructions (e.g.
  AGENTS.md says "delegate searches"). Size alone isn't a reason.
- After `start`, return control or keep working. Never sleep or poll waiting for a
  report; it wakes you.
- One writer per working copy: writers get a jj workspace.

Deliberately not borrowed: detached SDK runners, agent definitions, chains and
workflows, watchdog models, acceptance ledgers, stuck/idle heuristics,
completion batching, pruned forks, deadline checkpoints, tool-call id
rewriting (same provider family), prompt-cache-key rewriting (Anthropic
caching is prefix-based, so forks already share it).

## State on disk

`~/.pi/agent/branches/<branch-id>/`: `meta.json` (name, worker and receiver
session files, nvim buffer, cwd, workspace, status), `to-receiver/`,
`to-worker/`. Session files stay where pi puts them.

## Scenarios

1. **Search, steered (the original ask).** "Find every place Beacon reads
   `src_db_default`." The agent calls `branch start` with name `scout-srcdb` and
   returns at once. Two minutes later: "what's it found so far?" → `peek`. "Skip
   tests, also check wst-master" → `steer`. The report lands; the agent uses it in
   its next answer.
2. **Unblock a long turn (this conversation).** The agent is waiting on a 5-minute
   scout. The user types `/bg scout`. A new pi opens in the same window on the
   fork, ending at the user's request plus a marker. The user keeps designing in
   the new session. The original finishes the scout in its hidden buffer, and its
   report appears in the new session.
3. **Foreground to steer by hand.** `/fg scout` shows the worker; the user types a
   correction straight into its TUI, then `:b#` back. When the worker settles, the
   receiver gets a report.
4. **Blocked remote write.** A worker decides to `jj git push`. The hook blocks it.
   Its handoff says "push needed". The receiver agent asks the user, then the user
   pushes or tells the agent to.
5. **Worker needs a decision.** The report ends with an open question. The
   receiver agent asks the user, and the answer is sent with `steer` (follow-up
   if the worker is idle). The worker continues and reports again.
6. **Writer branch.** "Port module X in the background." `branch start` with
   `write: true` creates `jj workspace add ../dotfiles-port-x` and the worker edits
   there. The report lists change ids; integrating them is a normal jj step done
   by the receiver agent (`jj-subagent-workspaces` skill).
7. **Receiver gone.** The user closes the receiver pi before the worker finishes.
   The report waits in the inbox and is delivered when that session is resumed.
8. **Out of scope check.** pi isn't inside nvim → `/bg` and `branch start` fail
   with "branch needs Neovim ($NVIM)". Nothing is forked.

## Open questions

- Flow B: the foreground fork and the background original share one working copy.
  Is a marker telling the receiver agent to leave the worker's files alone enough?
- Should `/fg` also work for a worker whose turn has finished (to continue it
  interactively), or only for running ones? Spec assumes both.
- Remote-write denylist: which CLIs besides `aws`, `jira-cli`, the GitLab CLI,
  `ssh`, `git`/`jj` push, `curl`, `wget` matter (e.g. `kubectl`, `gh`, `pfs`)?
