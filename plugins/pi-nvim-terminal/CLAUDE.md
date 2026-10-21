# pi-nvim-terminal

Registers pi with the Neovim terminal it runs in, so servery.nvim can list and
restore pi sessions.

The shared rules (tests first, code hygiene, commits) are in `../CLAUDE.md`.

pi loads `index.ts` through `jiti`, so there is no build step. After an edit, run
`/reload` in a running pi, or load only this extension into a fresh one with
`pi --no-extensions --extension .`.

## Tests

No suite yet. `index.ts` has only type imports from pi, so it loads under
`node --test`. `nvim.lua` is tested from a headless nvim that `dofile`s it.

## Neovim side

- The TypeScript calls `nvim.lua` through `nvim --clean --headless --server $NVIM
  --remote-expr`, which `dofile`s it on every call. The Lua is stateless: keep state
  in the TypeScript or in buffer variables.
- Lua runs in the user's editor. It must not steal focus, prompt or block.
- The buffer name `term://<cwd>//<pid>:pi --session <file>` and `b:pi_session` are
  a contract: `servery.nvim` (`lua/servery/pi.lua`) and `pi.nvim` parse them.
  Change all three together.

## pi runtime

- Don't start timers, watchers, processes or sockets in the factory: some
  invocations load extensions without starting a session. Start them in
  `session_start` or in the command or tool that needs them, and stop them in an
  idempotent `session_shutdown` handler.
- Extensions also load in `pi -p` subagents and in branch sessions. Anything that
  assumes the user is watching a TUI must check `ctx.mode === "tui"` first.

## Style

TypeScript uses tabs; `nvim.lua` uses two spaces. `index.ts` opens with a doc
comment saying what the extension does; keep it true.
