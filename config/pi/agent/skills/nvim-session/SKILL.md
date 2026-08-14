---
name: nvim-session
description: Share a live Neovim session with the user via the `nv` CLI (msgpack-RPC over a unix socket) — read their cursor, visual selection, and unsaved buffer contents, read and change the session's working directory, and push results back as quickfix lists or by opening files at a line. Use when the user refers to "what I have open", "the code I selected/marked", "this buffer", asks you to put search results into their editor, or keeps one session open and expects you to work in different folders/projects through it. Also use before reading a file the user is actively editing, since the disk copy may be stale. NOT for editing files — make edits with the normal write/edit tools so they land on disk and jj sees them.
---

# nvim-session

Talks to a running Neovim over its msgpack-RPC socket. Two directions:

- **editor → agent**: cursor, visual selection, list of unsaved buffers, working
  directory of every scope
- **agent → editor**: populate the quickfix list, open a file at a line, re-root
  a scope's working directory

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
nv reload                  # re-read buffers whose file changed on disk
nv cwd                     # working directory of every scope
nv cd <dir> --scope S      # re-root a scope (S: global|tab|window|buffer)
nv cd --unset --scope S    # drop a local directory (S: tab|window|buffer)
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

### Reloading after something rewrote the working copy

`nv reload` is `:checktime` with guard rails. It exists for the checkout
workflow below: a `jj edit`, rebase or branch switch rewrites files underneath
the editor, and every open buffer becomes a stale copy of a file that has moved.
Read a stale buffer and you review code that is not on disk; worse, `mini.diff` /
gitsigns then compute hunks against the wrong text.

```bash
nv reload
```

```json
{"checked": 3, "buffers": [{"file": "/repo/a.py", "lines": 412}], "autoread_was": true}
```

- **Refuses, changing nothing, if any buffer is dirty**, and names the offenders.
  `:checktime` on a modified buffer either discards the user's edits or blocks on
  a prompt no RPC caller can answer. Neither is acceptable, so it does nothing.
- Sets `autoread` for the duration and restores it afterwards, even on failure,
  so the result does not depend on the user's config and the session is not left
  altered.
- `checked: 0` means nothing was open, not that reloading failed.

`nv open` also re-reads the file it opens (it runs `:edit`) and fires `BufEnter`,
which is what makes a diff plugin recompute its reference text. So after a
checkout, `nv open` on the file you are discussing is often enough; `nv reload`
is for every *other* buffer that is still stale.

## Working directory: read before you change

The user may keep **one session open** and expect you to work across different
folders through it. `nv cwd` reads where the session is rooted; `nv cd` moves it.

**Always `nv cwd` first.** A directory change is invisible in the editor — there
is no message, no statusline change — so the report is the only feedback anyone
gets:

```bash
nv cwd
```

```json
{
  "effective": "/path/to/project",
  "global": {"dir": "/path/to/project"},
  "tab":    {"dir": "/path/to/project", "local": false},
  "window": {"dir": "/path/to/project", "local": false},
  "buffer": {"dir": "/path/to/project", "local": false, "supported": true}
}
```

`effective` is what relative paths, `:find`, `:grep` and pickers resolve against
right now. `local: true` means that scope was set explicitly.

### The four scopes are not interchangeable

| `--scope` | Ex command | Who it moves | Sticky |
|---|---|---|---|
| `global` | `:cd` | the user's whole session | — |
| `tab` | `:tcd` | every window in the current tabpage | yes |
| `window` | `:lcd` | the current window | yes — new windows inherit it |
| `buffer` | `:bcd` | the current buffer only | no (nvim 0.13+) |

Pick by intent, and say which you used:

- **The user should follow you** into a new project → `--scope global` (or `tab`
  if they are keeping one project per tab). This changes what they see.
- **You need a root for your own work** without disturbing them → `--scope buffer`.
  Narrowest, and dies with the buffer.

`--scope` is required. There is deliberately no default, because the two
intentions above want opposite answers.

### Narrow scopes shadow wider ones

This is the trap. With a buffer-local directory set, `--scope global` succeeds
and `effective` does not move:

```
:bcd /a   →  effective=/a  buf_local=true
:cd  /b   →  effective=/a  buf_local=true   # global changed, effective did not
:bcd!     →  effective=/b  buf_local=false  # unset reveals it
```

If a re-root looks like it did nothing, read `effective` in the report — do not
re-issue the command. Drop the narrower scope instead:

```bash
nv cd --unset --scope buffer
```

The global scope has no unset (nothing wider to fall back to); pass it an
explicit directory.

Paths are resolved to absolute before being sent, so `nv cd` is never relative to
the editor's cwd — the thing being changed. `~` is rejected rather than guessed
at: pass it unquoted so the shell expands it, or pass an absolute path.

## Stale reads: check before you read

The `read` tool reads **disk**. If the user has unsaved changes you will silently
reason about code they no longer have.

Before reading a file the user is likely editing:

```bash
nv buffers --modified
```

If the file is listed, its buffer differs from disk. Say so, and work from the
buffer rather than quietly using a stale copy.

## Workflow: walking an MR commit by commit

For reviewing a stack of commits with the user, in their editor, one commit at a
time. The point is that the **gutter shows exactly one commit's changes** while
you talk through it.

### Why the gutter looks empty by default

Diff plugins compare the buffer against a reference that is normally the
working-copy parent — `jj @-`, or git `HEAD`, which in a colocated jj repo *is*
`@-`. Every commit that is already an ancestor of `@-` is therefore part of the
baseline, not a diff, and shows **no signs at all**.

So if the work is committed, there is nothing in the gutter. This is the normal
state, not a broken setup. Confirm it rather than guessing:

```bash
jj log -r @ -T 'commit_id.short(8)'      # where the working copy is
git merge-base --is-ancestor <rev> HEAD  # exit 0 => <rev> is behind the baseline
```

### The lever: move the working copy, not the plugin

`jj edit <commit>` makes `@` *be* that commit, so `@-` is its parent. A jj-aware
diff source then renders precisely that commit's hunks. **Prefer this to
reconfiguring the user's plugin** — it needs no plugin-specific verb, works for
any diff plugin keyed to `@-`/`HEAD`, and is one command to undo.

Do **not** use `jj new <commit>`: that makes `@` a *child*, so `@-` is the commit
itself and the buffer matches the reference — an empty gutter, the opposite of
what you want.

### Before you start

```bash
nv sockets                      # one live session? otherwise ask
nv cwd                          # read the current root BEFORE changing it
nv buffers --modified           # dirty buffers block the whole workflow
jj log -r @ -T 'change_id.short(8)'   # RECORD THIS - where to return to
```

The session is often rooted somewhere else (a parent folder holding many repos).
Two options, and they are not equivalent:

- **Absolute paths in `nv qf` / `nv open`, no re-root.** Least intrusive; changes
  nothing the user did not ask for. Default to this.
- **`nv cd <repo> --scope global`** when the user should *follow* you into the
  repo for the whole review, so their own `:find`, `:grep` and pickers resolve
  there too. Say that you did it, and restore it afterwards.

`jj edit` fails if the working copy is dirty, and `nv reload` refuses on dirty
buffers — so resolve unsaved work first rather than half-starting.

### Per commit

```bash
jj edit <commit>                     # @ = commit, so @- = its parent
nv reload                            # every open buffer is now stale
nv open <file> <line>                # re-reads + fires BufEnter -> refresh
cat items.json | nv qf "commit 3/6 - fix: parse ISO 8601 expires"
```

Then talk through it. One quickfix list **per commit**, titled `commit N/M - <subject>`
so the user always knows where they are, and one entry per hunk with an
annotation saying *why*, not what — the diff already says what.

Pause between commits. This is a conversation, not a batch job.

### Cleanup — always

```bash
jj edit <the change id recorded at the start>
nv reload
nv cd <original dir> --scope global   # only if you re-rooted
```

Leaving the user's working copy parked on some interior commit is a real hazard:
their next edit lands on it and silently amends a reviewed commit. Restore the
position even if the review is abandoned half way.

Record the **change id** (stable across rewrites), not the commit id, since
anything that rewrites the stack invalidates the latter.

### When the diff itself is the artifact

If the plugin story is uncertain, or the commit deletes files (nothing to open),
skip the gutter: write per-commit patches and open those instead. Neovim
highlights `.diff` natively, and it works for any history without touching the
working copy or plugin config.

```bash
jj diff -r <commit> --git > /tmp/review/N-<commit>-<slug>.diff
nv open /tmp/review/N-<commit>-<slug>.diff 1
```

Quickfix entries can point *into* the patch file, so `:cnext` steps hunk to hunk
with your annotations attached. This is the fallback that always works.

## Scope

Read, annotate, navigate, and re-root only. There is deliberately no verb to
write buffer contents and no raw `lua` escape hatch:

- buffer writes bypass disk, so `jj` cannot see them
- arbitrary lua eval is arbitrary code execution in the user's editor

**This holds even when the user offers.** An `exec`/`lua` verb cannot be granted
once for one task — it is a permanent, unaudited channel into the editor for
everything afterwards. When a workflow seems to need one, look for the move that
makes it unnecessary: the commit-walkthrough above wanted
`:Gitsigns change_base`, and `jj edit` turned out to give a better result with no
new capability at all. Prefer changing the *world* the plugin observes over
reaching into the plugin.

If a narrow verb really is missing, add a **named, validated** one (as `reload`
is) rather than a general escape hatch, and say so in the Status section.

Make edits with the normal `write`/`edit` tools, then `nv open` the file to show
the user where to look.

`nv cd` is the one verb that changes editor state the user did not ask for
keystroke by keystroke. It earns its place because the alternative — one session
per project — is what the user is explicitly trying to avoid. It stays honest by
requiring an explicit `--scope` and reporting every scope before and after.

## Status

Working and tested: `sockets`, `ping`, `cursor`, `selection`, `buffers`, `qf`,
`open`, `cwd`, `cd` (all four scopes + `--unset`, verified against a throwaway
headless session, including the shadowing case above).

`reload`: happy path verified against a live session (including flag rejection
and `autoread` restore). **The dirty-buffer refusal is code-reviewed but not
exercised** — there is no write verb, so an unsaved buffer cannot be created to
test it. Treat that branch as unproven.

Not built: `marks`, `diagnostics`, `sign`, `diff`, and the editor-side wiring
(`serverstart`, `:PiMark`). See [TODO.md](TODO.md). If you need one of these,
ask — do not work around it.
