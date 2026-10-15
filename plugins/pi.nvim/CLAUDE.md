# pi.nvim

Helpers for pi terminals in Neovim: finds the terminal pi runs in, its directory and
jj workspace root, and `:Pi` types a slash command into it. The shared rules (tests
first, code hygiene, commits) are in `../CLAUDE.md`.

## Tests

No suite yet. The first change that needs one adds `tests/run.lua`, modelled on
`../servery.nvim/tests`.

## Conventions

- A pi terminal is recognised by its buffer name, `term://<cwd>//<pid>:<command>`
  with `pi` as the program. `pi-nvim-terminal` sets that name and servery.nvim
  parses it too. Change all three together.
- `jj_statusline` in the dotfiles' `config/nvim/init.lua` calls `root()` on every
  statusline redraw. Keep `cwd()` and `root()` cheap: no processes, no blocking.
- Tabs, LuaLS annotations on public functions.
