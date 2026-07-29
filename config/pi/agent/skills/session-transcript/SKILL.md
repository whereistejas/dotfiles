---
name: session-transcript
description: Read PAST pi session transcripts in compact form via the `pi-transcript` script. Finds sessions under ~/.pi/agent/sessions by id, cwd or date, and renders one as short Markdown (thinking summarised, tool calls digested, tool results dropped, base64 stripped). Use when reconstructing what happened in an earlier session — notably from the `worklog` skill — instead of reading the raw multi-megabyte JSONL.
---

# session-transcript

pi writes every session to a JSONL file at
`~/.pi/agent/sessions/<escaped-cwd>/<timestamp>_<session-id>.jsonl`.
Those files reach 2.6 MB and are mostly tool-result and base64 noise, so
they cannot be fed to a model directly. `pi-transcript` renders one as
compact Markdown — typically 3–25× smaller — keeping user turns,
assistant text, a one-line digest per tool call, and the session-shape
markers (model changes, compactions, branch summaries).

Primary consumer: the `worklog` skill, when it has to reconstruct a past
session in order to write the log for it.

## Script cheatsheet

```bash
cargo run -q --offline --manifest-path ~/.pi/agent/skills/session-transcript/scripts/pi-transcript/Cargo.toml -- --help
cargo run -q --offline --manifest-path ~/.pi/agent/skills/session-transcript/scripts/pi-transcript/Cargo.toml -- find [--id ID] [--cwd PATH] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--limit N] [--format table|json]
cargo run -q --offline --manifest-path ~/.pi/agent/skills/session-transcript/scripts/pi-transcript/Cargo.toml -- read [--thinking|--no-thinking] [--thinking-chars N] [--tools digest|none|full] [--results N] [--all-branches] [--grep PATTERN] ID
```

The CLI is a Rust binary crate at
`~/.pi/agent/skills/session-transcript/scripts/pi-transcript`. Invoke it
with `cargo run`, pointing `--manifest-path` at that crate so it runs
from your current directory. The first run builds it; later runs are a
fast freshness check. Always pass `--offline` — the crate builds from the
local registry cache and must never hit the network.

```bash
cargo run -q --offline \
  --manifest-path ~/.pi/agent/skills/session-transcript/scripts/pi-transcript/Cargo.toml \
  -- <SUBCOMMAND> [ARGS...]
```

Every example below is that same `cargo run … --` line with the
subcommand after `--`. Session files are treated as read-only input; the
tool never writes to `~/.pi/agent/sessions/`.

`--sessions-dir PATH` (global) overrides the search root, which otherwise
comes from `$PI_SESSIONS_DIR` or defaults to `~/.pi/agent/sessions`.

## `find` — locate a session

Streams every `~/.pi/agent/sessions/*/*.jsonl` line by line (no file is
loaded whole) and prints id, start, end, duration, message count, file
size and cwd, most recent first.

```bash
# the 5 most recent sessions, anywhere
… -- find --limit 5

# resolve a prefix
… -- find --id 019fa8ca

# everything that ran in a project on a given day
… -- find --cwd /Users/you/build/git/service-lib --since 2026-07-28 --until 2026-07-28

# machine-readable
… -- find --cwd service-lib --limit 3 --format json
```

`--cwd` matches the **header** `cwd` by equality or substring. Do not
infer the cwd from the escaped directory name in the path: a session
started in one directory routinely does work for another, and the
directory name only records where pi was launched.

`--since` / `--until` filter on the session start date (`YYYY-MM-DD`,
inclusive on both ends).

## `read` — render a session

`ID` is a full session id or any unique prefix; an ambiguous prefix is an
error listing the candidates.

```bash
# default rendering: thinking summarised, tool calls digested, results dropped
… -- read 019fa8ca

# leanest possible: just the conversation
… -- read --no-thinking --tools none 019fa8ca

# investigate what a tool was actually called with
… -- read --tools full 019fa8ca

# include tool output, capped at 300 chars per result
… -- read --results 300 019fa8ca

# only the turns mentioning a thing
… -- read --grep "jj describe" 019fa8ca
```

Options:

- `--thinking` / `--no-thinking` — assistant thinking blocks. Included by
  default.
- `--thinking-chars N` — truncate each thinking block to N chars
  (default 300, `0` = untruncated). Thinking is the second-largest source
  of bulk after tool results; leave the default unless you specifically
  need the reasoning in full.
- `--tools digest|none|full` — `digest` (default) prints one
  `→ <name> <args>` line per call with arguments truncated to 160 chars;
  `none` omits calls; `full` pretty-prints the arguments.
- `--results N` — include tool results, each truncated to N chars.
  Default `0`, which omits results entirely. Tool results are usually
  ~80% of a transcript, so raise this only when you need it.
- `--all-branches` — see below.
- `--grep PATTERN` — keep only entries containing PATTERN
  (case-insensitive substring).

`thinkingSignature`, `textSignature`, `thoughtSignature` and image
`data` are never parsed, so no base64 blob can reach the output.

Output shape:

```markdown
# Session 019fa8ca-c427-7d17-a5ed-e8650281064f
- cwd: /Users/you/build/git/service-lib
- started: 2026-07-28T12:54:48Z
- ended: 2026-07-28T15:11:16Z (2h 16m)
- messages: 213
- source: /Users/you/.pi/agent/sessions/…/…jsonl

## user · 12:54:48
…text…

## assistant · 12:54:52
(thinking) …
…text…
→ bash {"command":"jj log -r 'main..@'"}
→ read {"path":"src/main.rs"}
```

Session-shape markers are rendered as one-liners because they matter when
reconstructing a session:

```markdown
_[model: anthropic/claude-sonnet-5]_
_[thinking level: high]_
_[compaction: 224,547 tokens summarized]_
_[branch summary: returned from an abandoned branch at e0ec8f55]_
_[label: three roads on cdf6f66c]_
```

A `_[compaction: …]_` marker means everything before it was summarised
away mid-session: the assistant after that point was working from a
summary, not from the turns above it.

## Sessions are trees, not logs — read this

Every entry has `id` and `parentId`. A session file is an **append-only
tree**: when the user rewinds or edits an earlier message, pi appends a
new branch to the *same* file and the abandoned branch stays in it
forever. Reading the file top to bottom therefore interleaves work that
was thrown away with work that actually happened — which produces
confidently wrong work logs.

- **Default**: `pi-transcript read` takes the last entry in file order as
  the active leaf, walks `parentId` to the root, reverses, and renders
  only that path. It prints
  `_(N entries on abandoned branches omitted; --all-branches to include)_`
  whenever anything was skipped.
- **`--all-branches`**: renders every entry in raw file order, abandoned
  branches included. Use it only when you are specifically investigating
  what was tried and discarded.

Missing parents, duplicate ids, orphans and cycles are all handled
defensively — the walk stops rather than looping or panicking.

## Recipe: "what happened in directory X on date Y?"

```bash
# 1. find the session
cargo run -q --offline \
  --manifest-path ~/.pi/agent/skills/session-transcript/scripts/pi-transcript/Cargo.toml \
  -- find --cwd /Users/you/build/git/service-lib --since 2026-07-28 --until 2026-07-28

# ID                                    STARTED               ENDED                 DURATION   MSGS    SIZE  CWD
# 019fa8ca-c427-7d17-a5ed-e8650281064f  2026-07-28T12:54:48Z  2026-07-28T15:11:16Z    2h 16m    213    496K  …/service-lib

# 2. read it, using the id prefix
cargo run -q --offline \
  --manifest-path ~/.pi/agent/skills/session-transcript/scripts/pi-transcript/Cargo.toml \
  -- read 019fa8ca > /tmp/019fa8ca.md
```

If more than one session matches the day, read them in start order —
long-running work often spans several. If a session is still too large
after the default rendering, tighten it with
`--no-thinking --tools none` first, then re-add detail with `--grep` or
`--tools full` on the parts you care about.
