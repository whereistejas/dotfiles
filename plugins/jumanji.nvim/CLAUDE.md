# jumanji.nvim

A jj UI for Neovim: log views (`jumanji://log/…`), file contents and diffs at a
revision (`jumanji://<root>//<rev>/<path>`), annotate, a picker, the `:J` command
and a statusline component. The shared rules (tests first, code hygiene, commits)
are in `../CLAUDE.md`.

## Tests

No suite yet. The first change that needs one adds `tests/run.lua`, modelled on
`../servery.nvim/tests`.

## Conventions

- jj runs from `jj.lua` only. The exception is `:J` in `cmd.lua`, which runs the
  user's own jj command line in a terminal.
- `status.get` runs on every statusline redraw. It only reads the cache; jj is read
  in the background, and again after every jj operation in the repo (`watch.lua`).
  Keep that split.
- Tabs, LuaLS annotations on public functions.
