# pi-nvim-terminal

Registers pi with the Neovim terminal it runs in, so servery.nvim can list and
restore pi sessions.

A pi extension, loaded from this checkout through the `extensions` list in
`~/.pi/agent/settings.json` (in the dotfiles repo). pi runs TypeScript through
`jiti`, so there is no build step; `index.ts` is the entry point.

## Verify before handing over

There is no test suite, typecheck or linter set up here. Check each change by running
it:

- **Lua run inside Neovim** (`nvim.lua`): drive it from a throwaway headless nvim
  that loads the file with `dofile` and asserts on the result:

  ```bash
  nvim --clean --headless -l /tmp/check.lua
  ```
- **TypeScript**: load only this extension into a fresh pi with
  `pi --no-extensions --extension .`, or run `/reload` in a running pi after an
  edit.

## How the Neovim side works

- `index.ts` calls `nvim.lua` through `nvim --clean --headless --server $NVIM
  --remote-expr`, which `dofile`s it on every call. The Lua is stateless: keep
  state in the TypeScript or in buffer variables (`b:pi_session`).
- Lua runs in the user's editor. It must not steal focus, prompt or block.
- `b:pi_session` and the `term://…:pi --session <file>` buffer name are read by
  servery.nvim and pi.nvim. Change them together.

## Runtime lifecycle

- Don't start timers, watchers, processes or sockets in the factory: some
  invocations load extensions without starting a session. Start them in
  `session_start` or in the command or tool that needs them.
- Stop them in an idempotent `session_shutdown` handler.
- Extensions also load in `pi -p` subagents and in branch sessions. Anything that
  assumes the user is watching a TUI must check `ctx.mode === "tui"` first.

## Code hygiene

- **Abstractions over decision trees.** When a feature adds cases, extend or create a
  small abstraction with a clean API instead of growing `if`/`else` chains in event
  handlers. Handlers parse the event and delegate.
- **One way to do a thing.** Reuse existing helpers (`call` in `index.ts`) rather than
  re-implementing their logic inline.
- **No bloat.** The smallest change that meets the requirement. No speculative options,
  no dead code, no unused parameters, no defensive checks for states that can't occur.
- **Sparse comments.** Comment only the *why* that the code can't say: a pi or Neovim
  quirk, a non-obvious constraint. Never narrate what the next line does.
- **Match the surrounding style.** TypeScript uses tabs and `biome-ignore` comments
  where a lint must be silenced. `nvim.lua` uses two spaces. `index.ts` opens with a doc
  comment saying what the extension does.
