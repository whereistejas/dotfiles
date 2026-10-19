# servery.nvim

## Tests first

For every feature request or bug fix, first encode the requirements as tests in
`tests/`, run them and watch the new ones fail, then implement until they pass.

Run the suite with:

```bash
nvim --clean -l tests/run.lua           # all tests
nvim --clean -l tests/run.lua <filter>  # tests whose name contains <filter>
```

Tests spawn real headless nvims on sockets under `/tmp`. `:connect` and `:qall` are
recorded rather than run (see `tests/helpers.lua`), so a test asserts on what servery
*would* do to the attached UI and the current server.

## Code hygiene

- **Abstractions over decision trees.** When a feature adds cases, extend or create a
  small abstraction with a clean API (a method on `Session`, a function in the module
  that owns the concept) instead of growing `if`/`elseif` chains in command handlers.
  Command handlers parse arguments and delegate.
- **One way to do a thing.** Reuse existing helpers (`utils.switch_to`,
  `Session:switch`, `list_sessions`) rather than re-implementing their logic inline.
  Duplicated logic (e.g. the unsaved-buffers check) belongs in one function.
- **No bloat.** The smallest change that meets the requirement. No speculative options,
  no dead code, no unused parameters, no defensive checks for states that can't occur.
- **Sparse comments.** Comment only the *why* that the code can't say: a Neovim quirk,
  a non-obvious constraint. Never narrate what the next line does.
- **Explicit booleans.** Compare optional flags with `== true`, never `~= nil`; `false`
  is not `nil`.
- **Match the surrounding style.** Tabs, `stylua.toml`, existing naming, LuaLS
  annotations on public functions.
