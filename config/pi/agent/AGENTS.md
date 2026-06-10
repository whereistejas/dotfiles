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

## Environment
- Don't install global packages or modify shell rc files without confirmation
- Don't start long-running background processes without confirmation
