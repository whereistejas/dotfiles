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
