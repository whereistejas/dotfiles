---
name: nvim-session
description: Share a live Neovim session with the user via the `nv` CLI (msgpack-RPC over a unix socket) — read their cursor, visual selection, and unsaved buffer contents, and push results back as quickfix lists or by opening files at a line. Use when the user refers to "what I have open", "the code I selected/marked", "this buffer", or asks you to put search results into their editor. Also use before reading a file the user is actively editing, since the disk copy may be stale. NOT for editing files — make edits with the normal write/edit tools so they land on disk and jj sees them.
---

# nvim-session

Talks to a running Neovim over its msgpack-RPC socket. Two directions:

- **editor → agent**: cursor, visual selection, list of unsaved buffers
- **agent → editor**: populate the quickfix list, open a file at a line

## Principles

These are the contract. They matter more than any individual feature.

1. **Only ever use `nv`.** Never invoke `nvim` yourself, for any reason — not to
   start a session, not to attach, not to inspect one, not to find a socket.
   `nv` is the only permitted interface to the editor.
2. **Fail fast and loudly.** Invalid input is rejected immediately. Nothing is
   coerced, defaulted, or silently ignored. Every failure exits non-zero — an
   empty result and a dead editor never look alike.
3. **Parse, don't validate.** Arguments and quickfix items are parsed into typed
   values at the boundary. Past that point every value is known-good.
4. **Errors instruct.** Every failure names what was wrong and prints the usage
   for the command attempted. If you misuse `nv`, the error tells you how to use
   it — read it instead of guessing.

## Never touch Neovim directly

**Every interaction goes through `nv`. There are no exceptions.**

Forbidden, without exception:

- `nvim --server ... --remote-expr`, `--remote-send`, `--remote-ui`, `--remote`
- `nvim --headless`, `nvim --listen`, or starting an editor in any form
- `luafile`, `luaeval`, `nvim_exec_lua`, or any throwaway lua script
- `find`/`ls` to hunt for sockets — use `nv sockets`
- attaching to, restarting, or killing the user's session

**If `nv` cannot do something, stop and ask the user.** Lack of functionality is
not permission to improvise. Say which verb is missing, say what you need it to
do, and wait. Missing verbs are tracked in [TODO.md](TODO.md).

Those workarounds are why this tool exists. They reintroduce shell-quoting bugs,
they mutate the editor as a side effect (a stray `V` motion clobbers the system
clipboard when `clipboard=unnamedplus`), and they fail silently.

**If no session is running, ask the user to start one. Do not start it yourself.**

## Setup

Build once. This is the only non-`nv` command in this skill:

```bash
cargo build --release --manifest-path ~/.pi/agent/skills/nvim-session/scripts/nv/Cargo.toml
```

Binary: `~/.pi/agent/skills/nvim-session/scripts/nv/target/release/nv`

## Finding the session

Start here. `nv sockets` needs no socket of its own:

```bash
nv sockets
```

```json
{
  "sessions": [
    {"socket": "/Users/you/.cache/nvim.sock", "alive": true,
     "cwd": "/path/to/project", "file": "/path/to/project/src/main.rs"}
  ],
  "alive": 1,
  "note": "One session alive; use its socket value."
}
```

Then use that `socket` value for every other command:

```bash
export NVIM_AGENT_SOCKET=<socket from nv sockets>
```

- `alive: 0` → ask the user to start a session. Do not start one.
- `alive: >1` → ask the user which they mean. Do not guess. `cwd` and `file`
  identify each session; quote them when asking.

## Commands

```bash
nv sockets                 # discover sessions (no socket needed)
nv ping                    # liveness + api level
nv cursor                  # file, line, col, modified, line text
nv selection               # last visual selection
nv buffers                 # open buffers with modified flags
nv buffers --modified      # only unsaved ones
nv qf <title> < items.json # populate quickfix (title required)
nv open <file> <line>      # open at a line (line required)
nv help                    # usage
```

JSON on stdout. Errors on stderr, exit 1.

### Reading what the user selected

`nv selection` reads the `'<` / `'>` marks. It issues **no motions and writes no
registers**. Returns `{"selection": null}` when there is no prior selection —
that is a real answer, not an error.

### Pushing results to the quickfix list

The main agent → editor path. Prefer this over pasting long lists of paths and
line numbers into chat.

```bash
echo '[{"filename":"src/foo.zig","lnum":42,"text":"why this line matters"}]' \
  | nv qf "semantic search: node allocation"
```

Item fields: `filename` (non-empty string), `lnum` (integer ≥ 1), `text`
(non-empty string), optional `col` (integer ≥ 1). Unknown fields are rejected.
Send `[]` to clear the list.

## Stale reads: check before you read

The `read` tool reads **disk**. If the user has unsaved changes you will silently
reason about code they no longer have.

Before reading a file the user is likely editing:

```bash
nv buffers --modified
```

If the file is listed, its buffer differs from disk. Say so, and work from the
buffer rather than quietly using a stale copy.

## Scope

Read, annotate, and navigate only. There is deliberately no verb to write buffer
contents and no raw `lua` escape hatch:

- buffer writes bypass disk, so `jj` cannot see them
- arbitrary lua eval is arbitrary code execution in the user's editor

Make edits with the normal `write`/`edit` tools, then `nv open` the file to show
the user where to look.

## Status

Working and tested: `sockets`, `ping`, `cursor`, `selection`, `buffers`, `qf`,
`open`.

Not built: `marks`, `diagnostics`, `sign`, `diff`, and the editor-side wiring
(`serverstart`, `:PiMark`). See [TODO.md](TODO.md). If you need one of these,
ask — do not work around it.
