# pi-jj-commit-mention

Adds `@` autocomplete for jj bookmarks and commits, merged with pi's file
completion.

A pi extension, loaded from this checkout through the `extensions` list in
`~/.pi/agent/settings.json` (in the dotfiles repo). pi runs TypeScript through
`jiti`, so there is no build step; `index.ts` is the entry point.

## Verify before handing over

There is no test suite, typecheck or linter set up here. Check each change by running
it:

- **TypeScript**: load only this extension into a fresh pi with
  `pi --no-extensions --extension .`, or run `/reload` in a running pi after an
  edit.

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
- **One way to do a thing.** Reuse existing helpers rather than re-implementing
  their logic inline.
- **No bloat.** The smallest change that meets the requirement. No speculative options,
  no dead code, no unused parameters, no defensive checks for states that can't occur.
- **Sparse comments.** Comment only the *why* that the code can't say: a pi quirk,
  a non-obvious constraint. Never narrate what the next line does.
- **Match the surrounding style.** TypeScript uses tabs and `biome-ignore` comments
  where a lint must be silenced. `index.ts` opens with a doc comment saying what the
  extension does.
