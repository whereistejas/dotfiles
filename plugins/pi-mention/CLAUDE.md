# pi-jj-commit-mention

Adds `@` autocomplete for jj bookmarks and commits, merged with pi's file
completion.

The shared rules (tests first, code hygiene, commits) are in `../CLAUDE.md`.

pi loads `index.ts` through `jiti`, so there is no build step. After an edit, run
`/reload` in a running pi, or load only this extension into a fresh one with
`pi --no-extensions --extension .`.

## Tests

No suite yet. `index.ts` imports `pi-tui` at runtime, so it can't load under
`node --test`. Logic worth testing (parsing `@<path>:<query>`, matching
bookmarks and commits) moves into a module of its own first.

## pi runtime

- Don't start timers, watchers, processes or sockets in the factory: some
  invocations load extensions without starting a session. Start them in
  `session_start` or in the command or tool that needs them, and stop them in an
  idempotent `session_shutdown` handler.
- Extensions also load in `pi -p` subagents and in branch sessions. Anything that
  assumes the user is watching a TUI must check `ctx.mode === "tui"` first.

## Style

TypeScript uses tabs and `biome-ignore` comments where a lint must be silenced.
`index.ts` opens with a doc comment saying what the extension does; keep it true.
