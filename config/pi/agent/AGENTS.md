# Global Agent Instructions

## Safety / destructive actions
- Never modify or delete files/folders without explicit confirmation
- Never run destructive shell commands (`rm -rf`, `dd`, etc.) without confirmation
- Never run `find /` or other filesystem-wide scans from the root; scope searches to the project or a known directory
- `git commit` is allowed; never push, force-push, or rewrite history without confirmation
- Never modify files outside the current working directory without confirmation

## Version control
- Always use `jj` instead of `git` for VCS operations (status, diff, log, branches, etc.)
- Don't touch `.git` internals or `.jj` internals without confirmation

## Secrets / privacy
- Never read or echo secrets/credentials (`.env`, `~/.ssh`, keychains, tokens)
- Don't include secrets in commands, logs, or commit messages
- Redact tokens/keys if encountered

## Scope discipline
- Do only what's asked — no opportunistic refactors or "while I'm here" changes
- Don't add dependencies without confirmation
- Don't change formatting/lint configs unless requested
- Prefer the smallest viable change

## Code style
- Match existing style and conventions in the repo
- No unsolicited comments, docstrings, or README edits
- Don't leave TODOs or commented-out code behind

## Workflow
- Read before editing; check neighboring files for conventions
- For non-trivial changes, briefly state the plan before executing
- Run tests/typecheck/lint when available after edits, if relevant
- Don't fabricate APIs — verify by reading source or docs

## Communication
- Be concise; skip preamble and recaps
- Show file paths as clickable relative paths
- Surface assumptions explicitly; ask when ambiguous rather than guessing

## Tooling
- ripgrep (`rg`) recurses by default — never use `-r` for recursion (that's a grep-ism). In `rg`, `-r`/`--replace=TEXT` rewrites matched text in the output
- Never cluster `-r` with other short flags (e.g. `-rn`, `-rln`): `rg` consumes the trailing letters as the replacement string, silently corrupting results
- Default search: `rg -n "pattern"`. Files only: `rg -l "pattern"`. Both: `rg -ln "pattern"`
- If output looks "mangled," suspect flag misuse before blaming the terminal; verify with a tiny known-input test rather than rationalizing the result

## Environment
- Don't install global packages or modify shell rc files without confirmation
- Don't start long-running background processes without confirmation

## Editor / Neovim
- Editor is Neovim v0.12 (0.12.x); assume built-in LSP and modern APIs
- Don't recommend deprecated nvim-lspconfig commands (`:LspRestart`, `:LspStart`, `:LspStop`, `:LspInfo`)
- Prefer built-in equivalents: `:checkhealth lsp` for status, and the `vim.lsp` API (e.g. `vim.lsp.enable`, `vim.lsp.stop_client`) or reopening the buffer to reattach a server
