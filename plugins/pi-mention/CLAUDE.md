# pi-mention

Adds `@` autocomplete for jj bookmarks and commits, merged with pi's file
completion, and `@@` autocomplete for LSP symbols from the Neovim session pi
runs in.

The shared rules (tests first, code hygiene, commits) are in `../CLAUDE.md`.

pi loads `index.ts` through `jiti`, so there is no build step. After an edit, run
`/reload` in a running pi, or load only this extension into a fresh one with
`pi --no-extensions --extension .`.

## Tests

Run `node --test`. `index.test.ts` uses a Node module hook to stub `pi-tui`
and exercises bounded subprocess output and truncation through autocomplete.
`lsp.test.ts` covers the `@@` logic in `lsp.ts`, which imports nothing from pi.

## Neovim side

- `@@` calls `nvim.lua` through `nvim --clean --headless --server $NVIM
  --remote-expr`, which `dofile`s it on every call. It reuses the LSP clients
  already running in that session and never starts one.
- `--remote-expr` is synchronous, so the first call starts `workspace/symbol` and
  pi polls until it is done. Requests in flight live in `_G.pi_mention_symbols`.
- Lua runs in the user's editor. It must not steal focus, prompt or block.

## pi runtime

- Don't start timers, watchers, processes or sockets in the factory: some
  invocations load extensions without starting a session. Start them in
  `session_start` or in the command or tool that needs them, and stop them in an
  idempotent `session_shutdown` handler.
- Extensions also load in `pi -p` subagents and in branch sessions. Anything that
  assumes the user is watching a TUI must check `ctx.mode === "tui"` first.

## Style

TypeScript uses tabs and `biome-ignore` comments where a lint must be silenced;
`nvim.lua` uses two spaces.
`index.ts` opens with a doc comment saying what the extension does; keep it true.
