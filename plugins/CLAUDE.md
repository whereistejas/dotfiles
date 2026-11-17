# Plugins

Local Neovim plugins and pi extensions, one per folder. The dotfiles repo
loads them from here: Neovim plugins through `rtp:prepend` in `config/nvim/init.lua`,
pi extensions through the `extensions` list in `config/pi/agent/settings.json`. Each
plugin's own `CLAUDE.md` adds what is specific to it, including how to run its tests.

## Tests first

For every feature request or bug fix, first encode the requirements as tests, run
them and watch the new ones fail, then implement until they pass. The tests are the
spec.

A repo without a test suite gets one in the first change that needs it:

- **Lua**: `tests/run.lua`, run with `nvim --clean -l tests/run.lua [filter]`.
  Tests spawn real headless nvims. `servery.nvim/tests` is the model to copy.
- **TypeScript**: `*.test.ts` files run with `node --test`. Node 22 runs TypeScript
  directly and `node:test` is built in, so this adds no dependency. Node only
  strips types, so two things stop a module loading there:
  - a value import from pi's packages, directly or through another module
    (`import type` is erased and fine)
  - syntax that needs compiling: parameter properties, `enum`, `namespace`

  Keep the logic worth testing in modules free of both.

## Code hygiene

- **Abstractions over decision trees.** When a feature adds cases, extend or create a
  small abstraction with a clean API (a method on the type, a function in the module
  that owns the concept) instead of growing `if`/`elseif` chains in command or event
  handlers. Handlers parse their input and delegate.
- **One way to do a thing.** Reuse existing helpers rather than re-implementing their
  logic inline. Duplicated logic belongs in one function.
- **No bloat.** The smallest change that meets the requirement. No speculative options,
  no dead code, no unused parameters, no defensive checks for states that can't occur.
- **Sparse comments.** Comment only the *why* that the code can't say: a Neovim or pi
  quirk, a non-obvious constraint. Never narrate what the next line does.
- **Match the surrounding style.** Existing naming, indentation and annotations (LuaLS
  annotations on public Lua functions).

## Commits

Commit as `Tejas Sanap <email@whereistejas.xyz>`. The global jj config uses a
different address, so run jj commands that create or rewrite commits with
`JJ_USER="Tejas Sanap" JJ_EMAIL=email@whereistejas.xyz`.
