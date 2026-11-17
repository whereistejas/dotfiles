# pi.nvim

Helpers for pi terminals in Neovim: finds the terminal pi runs in, its directory and
jj workspace root, and `:Pi` types a slash command into it. After a session loads,
it starts the pi terminals the session restored hidden. In a pi terminal, `gd`
finds the symbol under the cursor through `workspace/symbol` and opens it in a
code window. The shared rules (tests
first, code hygiene, commits) are in `../CLAUDE.md`.

## Tests

Run `nvim --clean -l tests/run.lua [filter]`. Tests spawn headless nvims with this
plugin and a fake `pi` on their `PATH` (`tests/helpers.lua`).

## Conventions

- A pi terminal is recognised by its buffer name, `term://<cwd>//<pid>:<command>`
  with `pi` as the program. `pi-nvim-terminal` sets that name and servery.nvim
  parses it too. Change all three together.
- `jj_statusline` in the dotfiles' `config/nvim/init.lua` calls `root()` on every
  statusline redraw. Keep `cwd()` and `root()` cheap: no processes, no blocking.
- Tabs, LuaLS annotations on public functions.
