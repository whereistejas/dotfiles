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

pi now runs in a `:terminal` of the same session, which opens a path that did
not exist before: the keymap can find pi's terminal buffer and `chansend()` the
payload to its job as a bracketed paste, exactly as if the user had pasted it.

**Unverified — do not assume this works yet.**

1. Does pi's TUI accept a bracketed paste of multi-line text into the editor
   without submitting it? It must land as a draft, not a sent prompt.
2. Which terminal is pi's? Match `b:terminal_job_pid` against pi's process
   tree, not the terminal title.
3. Fallbacks, only if 1 fails: an extension listening on a socket or fifo
   (`docs/extensions.md`, `examples/extensions/`), else a spool file
   (`~/.cache/pi-inbox/*.md`) the agent drains on request.

A keybinding that silently no-ops is worse than one that doesn't exist.

## 2. More recipes

- Diagnostics for the code window's buffer (`vim.diagnostic.get`).
- Signs / extmarks to annotate lines without touching the quickfix list.
- `:PiMark`: a user command appending the selection to a queue the agent
  drains — only if §1 doesn't pan out.

## 3. Hardening

- Automate the throwaway-session checks in SKILL.md's Status section. They
  were run by hand (headless session with `-n`, code window + terminal,
  torn down after); a regression in a recipe or in `rpc.lua` would go
  unnoticed.
- Chunk error line numbers include `prelude.lua`'s lines. `rpc.lua` could
  take the prelude as a separate chunk so `chunk:N` matches the heredoc.
- Directory changes leave no audit trail. If a stale `:lcd` from an earlier
  request confuses a later one, there is no way to see who set it. Consider
  recording agent-issued changes in a session variable the cwd recipe reports.
