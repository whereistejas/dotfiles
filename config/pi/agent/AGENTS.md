# Global Agent Instructions

## Communication

**No walls of text.** Be concise; skip preamble and recaps.

One topic per message. Several things → several short messages, one at a time, never
bundled. Assume limited reading bandwidth: never make me ingest and act on a lot at once.

Tone:
- Show file paths as clickable relative paths
- Surface assumptions explicitly; ask when ambiguous rather than guessing
- Never validate or flatter my asks or choices. No "good intuition to check X before Y",
  "great question", "smart to verify Z", "you're right to...". Just answer or do the work

## Safety

Ask for explicit confirmation before you:
- Modify or delete any file or folder
- Modify anything outside the current working directory
- Run destructive shell commands (`rm -rf`, `dd`, etc.)
- Push (except as allowed under Code style → commits), force-push, or rewrite history
  (plain commits are fine)
- Touch `.git` or `.jj` internals
- Install global packages or modify shell rc files
- Add a dependency
- Start a long-running background process

Never run `find /` or other filesystem-wide scans from the root; scope searches to the
project or a known directory.

## Secrets

- Never read or echo secrets and credentials (`.env`, `~/.ssh`, keychains, tokens)
- Exception: the macOS keychain `personal-tokens` namespace (service prefix
  `personal-tokens.*`) may be read when a task needs those credentials. Pipe the values
  straight into commands — never echo, log, or print them
- Keep secrets out of commands, logs, and commit messages; redact any you encounter

## Scope discipline

- Do only what's asked — no opportunistic refactors or "while I'm here" changes
- Prefer the smallest viable change
- Don't change formatting or lint configs unless asked

## Code style

- Match the existing style and conventions of the repo
- No unsolicited comments, docstrings, or README edits
- Don't leave TODOs or commented-out code behind
- **Make small, logical commits as you go and push them to the git remote.** One coherent
  change per commit. Before starting the work, confirm once with me that pushing as you
  go is OK for this task; after that, push each commit without asking again. Force-push
  and history rewrites still need explicit confirmation

### Rust

- **Divide code into paragraphs.** Separate logically distinct blocks within a
  function with a blank line.
- **No inline imports, even in tests.** All `use` statements go at the top of the
  module, never inside a function or block.
- **Order imports in groups:** `std`, external crates, internal (workspace) crates,
  `crate`, `super` — one blank line between groups.
- **No glob imports.** No `use super::*`, `use crate::foo::*`, or similar; name
  each item.
- **`#[expect(lint, reason = "...")]`, not `#[allow]`.** An `expect` warns once
  the suppression is no longer needed.
- **No narrowing `as` casts.** Use `From` / `TryFrom`; `as` truncates silently.
- **`expect("<invariant>")`, not bare `unwrap()`, outside tests.** The message
  states why the value cannot be absent.
- **Every `unsafe` block carries a `// SAFETY:` comment** stating the invariant
  that makes it sound.
- **No `.clone()` to appease the borrow checker.** Restructure the borrow instead.

## Workflow

- For non-trivial changes, briefly state the plan before executing
- Run tests/typecheck/lint after edits when available and relevant
- Don't fabricate APIs — verify by reading source or docs
- Keep `AGENTS.md` in sync: when a change invalidates something it documents (moved or
  renamed paths, changed commands, env vars, workflows, conventions), update `AGENTS.md`
  in the same turn — don't defer or wait to be asked

## Version control

Always use `jj` instead of `git` for VCS operations (status, diff, log, bookmarks, etc.).

### Avoiding interactive jj commands

When stdin is not a terminal — as it is for you — interactive `jj` commands abort with
"Command aborted" instead of prompting. That wastes a turn and creates confusion.

Before running an unfamiliar jj command, check its help:

```bash
jj <command> --help | head -n 30
```

Warning signs in the output:
- A parameter documented as "default: @" or "default: working-copy" — it needs an
  explicit `-r`, or `--from`/`--into`
- The word "interactive" in the description
- An `-i` / `--interactive` flag

Interactive by default:
- `jj squash` without `--from`/`--into`
- `jj squash -r <rev>` — still interactive; use `--from`/`--into`
- `jj squash --from <src> --into <dst>` — opens `$EDITOR` when both commits have
  descriptions, which hangs with no terminal
- `jj split` without file paths — use the `jj-surgeon` skill / `jj-hunk-tool`
- `jj resolve` without `-r <rev> --tool <tool>`

Safe patterns:

```bash
# Squash: always pass --from and --into, plus -u (use destination message)
# or -m "..." so no editor opens
jj squash --from <source-rev> --into <dest-rev> -u
jj squash --from <source-rev> --into <dest-rev> -u --keep-emptied

# Split: by file, or by hunk via jj-hunk-tool (see the jj-surgeon skill)
jj split path/to/file -m "commit message"
jj-hunk-tool hunks                       # list hunk IDs
jj-hunk-tool split <hunk-id> -m "commit message"

# Resolve conflicts
jj resolve -r <rev> --tool <tool>
```

### Combining many commits into one

Chained `jj squash --from` calls create divergence. Rebuild from the base instead:

```bash
jj new <base-commit>                     # start fresh on the base
jj restore --from <tip-commit>           # take the final state from the tip
jj describe -m "Combined commit message"
```

That yields one clean commit with all the changes and no divergence. If you do end up
with divergent commits, `jj abandon 'divergent()'` and redo it with the pattern above.

## Tooling

ripgrep (`rg`) recurses by default — never use `-r` for recursion, that's a grep-ism. In
`rg`, `-r`/`--replace=TEXT` rewrites the matched text in the output.

- Never cluster `-r` with other short flags (`-rn`, `-rln`): `rg` swallows the trailing
  letters as the replacement string and silently corrupts the results
- Default search: `rg -n "pattern"`. Files only: `rg -l "pattern"`. Both: `rg -ln "pattern"`
- If output looks mangled, suspect flag misuse before blaming the terminal; verify with a
  tiny known-input test rather than rationalizing the result

## Environment

`pi` is installed globally with npm under the nvm default node (v22.21.1):
`~/.nvm/versions/node/v22.21.1/bin/pi` →
`.../lib/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js`, run with a
`node` shebang. No bun install, no `~/.local/bin/pi` wrapper — bare `pi` works in any shell.

## Editor / Neovim

The editor is Neovim nightly (`v0.13.0-dev`, Homebrew). Assume built-in LSP and current
APIs.

- Don't recommend deprecated nvim-lspconfig commands (`:LspRestart`, `:LspStart`,
  `:LspStop`, `:LspInfo`)
- Use the built-in equivalents: `:checkhealth lsp` for status, and the `vim.lsp` API
  (`vim.lsp.enable`, `vim.lsp.stop_client`), or reopen the buffer to reattach a server
