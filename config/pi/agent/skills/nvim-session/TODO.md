# nvim-session — TODO

## 1. Send a code block from nvim into a live `pi` conversation

Requested: a keybinding (à la Cursor / VS Code "Add to Chat") that takes the
current visual selection and drops it into the conversation the user is
actively having with `pi`.

Shape:

```
visual select → <leader>pa → block lands in the running pi session
```

Payload should be `file:start-end` + the selected lines + `modified` flag, so
the agent reads the *buffer* state, not a stale disk copy.

**Blocking unknown — do not assume this works yet.**

`pi` exposes an RPC mode (`docs/rpc.md`) with `prompt`, `steer` and `follow_up`
commands as line-delimited JSON. But RPC mode is how you *drive pi headlessly
over stdin/stdout* — it is not evidence that an already-running interactive TUI
session listens on anything. Those are different things, and the feature only
works if the second is possible.

Investigate, in order:

1. `docs/extensions.md` + `examples/extensions/` — can an extension register a
   listener (socket/fifo/file watch) that injects into the current session?
2. `docs/rpc.md` §`steer` / §`follow_up` — reachable from outside RPC mode?
3. `docs/packages.md`, `docs/sdk.md` — any supported side channel.
4. Fallback if none: write to a spool file (`~/.cache/pi-inbox/*.md`) that the
   agent drains on request. Degrades "push" to "pull", but always works.

Reject the fallback only after 1–3 are actually ruled out — a keybinding that
silently no-ops is worse than one that doesn't exist.

## 2. Open design decisions (blocking the rest of the skill)

Carried over, still unanswered:

- **Socket discovery** — fixed path (`~/.cache/nvim-agent.sock`) vs scanning
  `$TMPDIR/nvim.*/`; per-project sockets keyed by cwd?
- **Disambiguation** — 2+ live servers seen in practice. Fail loud, or pick by cwd?
- **Write access** — read + annotate + quickfix only, or may the agent write
  buffers? (Leaning read-only; buffer writes bypass disk and confuse `jj`.)
  Partly settled: `nv cd` is allowed to change directory scope, because one
  long-lived session across many folders is the whole point. Buffer *contents*
  stay off limits.
- **Raw `lua` escape hatch** — flexible, but arbitrary code execution in the
  editor. Leaning no.
- **No-session policy** — hard-fail, or fall back to disk reads? Silent fallback
  reintroduces the stale-read bug. Leaning hard-fail.
- **Commit or gitignore?** — every Rust-CLI skill (`jira`, `gitlab`, `bi-mcp`,
  `gitolite`, `beacon-code-review`) is gitignored; `session-transcript` and
  `subagents` are tracked. Unclear whether that's `target/` bloat or secrets.

## 3. Editor-side wiring not yet written

- `vim.fn.serverstart()` in `init.lua` (or a shell alias) so a socket always exists.
- `:PiMark` command + keymap appending the selection to a drainable queue.
- `nv marks` verb to drain that queue.
- `nv diagnostics`, `nv sign`, `nv diff` verbs.

Done: `nv cwd` / `nv cd --scope global|tab|window|buffer` / `nv cd --unset`.

## 4. Hardening

- `nv doctor` self-check (socket present, reachable, API level ≥ 12).
- Test suite against throwaway headless nvim instances. `cwd`/`cd` were verified
  this way by hand (throwaway socket, torn down after); nothing is automated yet,
  so a regression in the scope handling would go unnoticed.
- `nv cd` leaves no audit trail. If a stale `:lcd` from an earlier request
  confuses a later one, there is no way to see who set it. Consider recording
  agent-issued directory changes somewhere the user can inspect.
- Decide vendored/`--offline` cargo (like `bi-mcp`) vs plain crates.io.
