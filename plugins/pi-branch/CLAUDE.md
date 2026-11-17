# pi-branch

Forks the current pi conversation, or starts a fresh one, in a background pi
session in a Neovim terminal buffer, and posts its result back when it settles. `SPEC.md` is the
design. Update it in the same change when behaviour changes.

The shared rules (tests first, code hygiene, commits) are in `../CLAUDE.md`.

pi loads `index.ts` through `jiti`, so there is no build step. After an edit, run
`/reload` in a running pi, or load only this extension into a fresh one with
`pi --no-extensions --extension .`.

## Tests

Run `node --test` with Node 22 (the nvm default, which pi runs on); Homebrew's
Node 26 can't load the worker tests. `nvim.test.ts` drives `nvim.lua` through `nvim.ts` against a
headless nvim it starts; `workspace.test.ts` runs `agent-workspace` (so it must be
on `PATH`) on throwaway jj repos, including a tiny crate that `cargo` builds.
`policy.ts` and `store.ts` load there too. `reporting.test.ts` and
`brief.test.ts` import `test-hooks.ts`, whose Node module hooks replace pi
imports, transform worker parameter properties, and isolate branch storage in a
temporary directory.

## Neovim side

- The TypeScript calls `nvim.lua` through `nvim --clean --headless --server $NVIM
  --remote-expr`, which `dofile`s it on every call. The Lua is stateless: keep state
  in the TypeScript or in buffer variables.
- Lua runs in the user's editor. It must not steal focus, prompt or block.
- A terminal started with `jobstart(…, { term = true })` under `nvim_buf_call` takes
  the size of nvim's 5-row autocmd window and keeps it while hidden. Always pass
  `width`/`height`. At 5 rows, pi's TUI reprints its whole history on every frame,
  which makes the whole editor lag.
- `b:pi_branch` marks a branch's terminal buffer.

## pi runtime

- Don't start timers, watchers, processes or sockets in the factory: some
  invocations load extensions without starting a session. Start them in
  `session_start` or in the command or tool that needs them, and stop them in an
  idempotent `session_shutdown` handler.
- Extensions also load in `pi -p` subagents and in branch sessions. Anything that
  assumes the user is watching a TUI must check `ctx.mode === "tui"` first.

## Style

TypeScript uses tabs; `nvim.lua` uses two spaces. Reuse `call` in `nvim.ts` for
every Neovim call and `store.ts` for every file under `~/.pi/agent/branches`.
