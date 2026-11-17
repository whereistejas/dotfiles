# servery.nvim

The shared rules (tests first, code hygiene, commits) are in `../CLAUDE.md`.

## Tests

Run the suite with:

```bash
nvim --clean -l tests/run.lua           # all tests
nvim --clean -l tests/run.lua <filter>  # tests whose name contains <filter>
```

Tests spawn real headless nvims on sockets under `/tmp`. `:connect` and `:qall` are
recorded rather than run (see `tests/helpers.lua`), so a test asserts on what servery
*would* do to the attached UI and the current server.

## Conventions

- Command handlers parse arguments and delegate to a method on `Session` or a
  function in the module that owns the concept.
- Reuse `utils.switch_to`, `Session:switch` and `list_sessions` rather than
  re-implementing them. Checks used in several places, such as the unsaved-buffers
  check, live in one function.
- **Explicit booleans.** Compare optional flags with `== true`, never `~= nil`; `false`
  is not `nil`.
- Tabs, `stylua.toml`.
