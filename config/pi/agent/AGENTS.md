# Global Agent Instructions

## Communication

**No walls of text.** Be concise; skip preamble and recaps.

One topic per message. Several things → several short messages, one at a time, never
bundled. Assume limited reading bandwidth: never make me ingest and act on a lot at once.

Tone:
- Show file paths as clickable relative paths: every path relative to the cwd, with
  `:line` when pointing at code, so Neovim's `gF` opens it. Never shorten a path relative
  to a base directory named earlier, and never give a bare file name. Write
  `../repo/crates/codegen/src/resolve/avro.rs:23`, not `resolve/avro.rs:23` or `avro.rs:23`
- Name the code a location points at, qualified the way the language writes it, before
  its path: `avro::resolve` (crates/codegen/src/resolve/avro.rs:23), `Yield::of`
  (crates/codegen/src/resolve/check.rs:214). When the line falls inside an item rather
  than on its definition, name the enclosing item: `Kind::of`
  (crates/codegen/src/resolve/mod.rs:179)
- Surface assumptions explicitly; ask when ambiguous rather than guessing
- Never validate or flatter my asks or choices. No "good intuition to check X before Y",
  "great question", "smart to verify Z", "you're right to...". Just answer or do the work

Diagrams: the chat can't render Mermaid. Render every diagram with `mmdc` (pass a puppeteer
config pointing at the system Chrome) and open the image for me (`open <file>.png`); never
show Mermaid source alone. For diagrams in documents, also check they render in the target
renderer (GitLab's Mermaid version) and avoid syntax newer than it.

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

Exception: create and remove jj workspaces for your own or a subagent's work with
`agent-workspace` (see Version control → Agent workspaces) without asking, including the
warm-up build it starts and deleting a workspace's folder once its work is integrated or
dropped.

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
- **Push first, check after, when the branch has CI.** Once an approved push or
  force-push (a rebase, a restack, a lockfile bump) is ready and conflict-free, push it
  and open or retarget the MR before running fmt, `cargo check`, clippy or tests
  locally. CI runs them anyway; running them first serialises minutes of waiting in
  front of the push. Run them locally afterwards, in parallel with CI, and fix forward.
  The same goes for briefs you write for branches and subagents: never make a local
  check a gate before their push
- Don't block on long tasks. Tests, builds, and running scripts you created go to a
  background task (a subagent or a `branch`, chosen as below) when they may take more
  than ~1 minute; return control
  instead of waiting. Large scans and investigations may run in blocking mode
- **Choose a forked branch vs a subagent by context, not habit.** Both are `branch`
  tool sessions: a pi TUI in a hidden Neovim terminal that the user can join from the
  servery picker, and that reports back on its own. Never run headless `pi -p`
  subagents
  - **Subagent** (`branch` with `fresh: true`; the `subagents` skill) when the task fits
    in a written brief: base, files, steps, checks, what to push. Mechanical refactors,
    rebases, lockfile bumps and doc syncs are all of this kind. It starts with no
    conversation, so every turn is fast and you can pick the model (sonnet for code,
    haiku for ops)
  - **Forked branch** (`branch` without `fresh`) only when the task needs this
    conversation's unwritten context (open judgement calls, nuance from the discussion)
    and the conversation is still short
  - Once the conversation is long, prefer subagents: a forked branch re-reads the whole
    fork on every step, and the fork may not fit a small model at all
  - Test: if you're writing a full brief anyway, that's a subagent
- Don't fabricate APIs — verify by reading source or docs
- Keep `AGENTS.md` in sync: when a change invalidates something it documents (moved or
  renamed paths, changed commands, env vars, workflows, conventions), update `AGENTS.md`
  in the same turn — don't defer or wait to be asked

## Version control

Always use `jj` instead of `git` for VCS operations (status, diff, log, bookmarks, etc.).

### Agent workspaces

Create and remove jj workspaces with `agent-workspace` (the dotfiles' `scripts/`, on
`PATH`), never with raw `jj workspace add` / `forget` / `rm -rf`:

```bash
agent-workspace add <name> [<revision>]  # sibling <repo>-<name>; prints dir=<path>, and brief=<line> in Rust
agent-workspace remove <dir>             # stops its warm-up, forgets it (edits stay in its commit), deletes it
```

- It always passes `--colocate`, so the workspace gets its own Git worktree and
  git-based tooling (editors, hooks, build scripts) works in it. This overrides any
  skill that says workspaces lack `.git/`
- In a Rust project, `add` clones the source workspace's `target/` (APFS clonefile:
  instant, no extra disk) and starts a background warm-up build, so nobody waits
  minutes on a cold build. Put its `brief=` line into the task of whoever works there,
  and don't wait for the warm-up yourself: research and edit meanwhile
- `branch` with `write: true` runs `agent-workspace add` itself and passes the `brief=`
  line on, for forked branches and subagents alike
- Clean up everything you created once the work is integrated or dropped:
  `branch close` for a branch or subagent (it also wipes its Neovim buffer and removes
  its workspace), `agent-workspace remove <dir>` for one you added by hand. A branch
  never removes its own workspace

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

### Pi gateway authentication

`extensions/aigw/index.ts` supplies gateway authentication with a five-minute,
process-local token cache and asynchronous `aigw token` lookups. Omit `apiKey` from
that provider in `models.json`; a configured key overrides the extension and a
`!command` restores synchronous per-request lookups. Cached tokens are refreshed
30 seconds before their declared expiry when that is sooner than five minutes.
Run `node --test tests/pi-token-cache.test.mjs` from the dotfiles root to test it.

## Editor / Neovim

The editor is Neovim nightly (`v0.13.0-dev`, Homebrew). Assume built-in LSP and current
APIs.

- Don't recommend deprecated nvim-lspconfig commands (`:LspRestart`, `:LspStart`,
  `:LspStop`, `:LspInfo`)
- Use the built-in equivalents: `:checkhealth lsp` for status, and the `vim.lsp` API
  (`vim.lsp.enable`, `vim.lsp.stop_client`), or reopen the buffer to reattach a server
