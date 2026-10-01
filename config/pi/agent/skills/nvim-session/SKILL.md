---
name: nvim-session
description: Share the user's live Neovim session — the servery.nvim session whose terminal pi is running in ($NVIM) — by running Lua in it over msgpack-RPC with `nvim --clean -l rpc.lua`. Read their cursor, visual selection, unsaved buffers and working directories; push results back as quickfix lists, open files at a line in a code window, reload buffers after a checkout, and re-root a directory scope. Use when the user refers to "what I have open", "the code I selected/marked", "this buffer", asks you to put results into their editor, or expects you to work in another folder through their session. Also use before reading a file the user may be editing, since the disk copy may be stale. NOT for editing files — make edits with the normal write/edit tools so they land on disk and jj sees them.
---

# nvim-session

pi runs in a terminal inside a Neovim session, usually a
[servery.nvim](https://github.com/whereistejas/servery.nvim) one. That session's
RPC socket is in `$NVIM`. This skill talks to it directly through the Neovim
API: a throwaway `nvim --clean -l` process connects, runs a Lua chunk inside the
session via `nvim_exec_lua`, and prints the return value as JSON.

## Running a chunk

```bash
SK=~/.pi/agent/skills/nvim-session/scripts
cat "$SK/prelude.lua" - <<'LUA' | nvim --clean -l "$SK/rpc.lua"
return { cwd = vim.fn.getcwd(), modified = modified_files() }
LUA
```

- Always quote the heredoc (`<<'LUA'`) so the shell leaves the Lua alone. Put
  values (paths, line numbers, titles) into the chunk as Lua literals.
- `prelude.lua` defines `code_win()`, `is_code_win(win)` and `modified_files()`
  (see below). Always prepend it; it costs nothing. Error line numbers count the
  prelude's lines too.
- `--clean` is required: the client must not load the user's config, plugins or
  servery.
- Output is the chunk's return value as JSON (`nil` → `null`) on stdout.
  Errors go to stderr. Exit `1` is a usage or Lua error, exit `2` is a timeout.
- Flags: `--server SOCK` (default `$NVIM`), `--timeout SECS` (default 10), and an
  optional `ARGS_JSON` array that becomes the chunk's `...`.

`rpc.lua` never blocks on the session. It sends the chunk as a notification and
awaits the reply notification with `vim.async.timeout`. If the session is stuck
(e.g. on a prompt), you get exit 2. **Tell the user; do not retry in a loop.**

### Finding the session

```bash
nvim --clean -l "$SK/rpc.lua" --sessions
```

```json
[{"self": true, "socket": ".../servery.nvim/dotfiles20261001-141310.pipe",
  "cwd": "/Users/you/build/dotfiles", "original_cwd": "/Users/you/build/dotfiles",
  "uis": 1, "pid": 13257}]
```

It lists every servery and plain nvim session. Sessions that are alive but
unresponsive come back with `"error": "timeout"`.

- **Target `self` (the `$NVIM` session).** Use `--server` for a different
  session only when the user asks for it by name or directory.
- **`uis: 0` on `self` means the user has switched to another servery session**
  and won't see anything you push until they come back. Say so before relying
  on the quickfix list or an opened file.
- `$NVIM` unset means pi is not running inside nvim. Ask the user which
  session they mean (show them `--sessions`). Never start one yourself.

## Hard rules

`rpc.lua` runs **arbitrary Lua in the user's editor**. Nothing in the tool
stops a destructive chunk; these rules are the only guard rails.

1. **The current window is pi's own terminal.** Never `:edit`, `:bdelete`,
   `:close` or resize it, and never send it input (`chansend`, `nvim_input`,
   `nvim_feedkeys`): that types into pi, and the user is typing there too. Read
   and open code through `code_win()`, never through window `0`.
2. **Don't steal focus.** Open windows with `enter = false`, and use
   `nvim_win_call` to act in a window. No `nvim_set_current_win` unless asked.
3. **Nothing that prompts or blocks.** No `input()`, `confirm()` or
   `getchar()`. No `:checktime` with modified buffers, no `:edit!`, no `:q`.
   A prompt freezes the user's editor until they answer it.
4. **No motions, no registers.** With `clipboard=unnamedplus`, a stray yank
   clobbers the system clipboard. Read text with `nvim_buf_get_lines`,
   `nvim_buf_get_mark` and `getregion()`, never with `normal! gv"y`.
5. **No buffer writes.** No `nvim_buf_set_lines`, `:write`, `:substitute`.
   Buffer edits bypass disk, so `jj` can't see them. Edit files with the
   write/edit tools, then reload or open.
6. **Hands off the session lifecycle.** No `:qa`, `:restart`, `:connect`,
   `:detach`, `:Sv*`, `serverstart`/`serverstop`, and no spawning nvim
   (beyond `nvim --clean -l rpc.lua`). If no usable session exists, ask.
7. **Leave no trace.** Don't change options, keymaps, autocmds or globals
   persistently. If a chunk must flip an option, restore it in the same chunk,
   even on failure (see the reload recipe).

The only standing exceptions are the recipes below: setting the quickfix list,
opening a file in a code window (creating a split if there is none), and
re-rooting a directory scope. Anything else that changes the session: ask
first.

## Prelude

```lua
is_code_win(win)   -- normal (non-floating) window showing a file buffer
code_win()         -- the user's code window in the current tab: the current
                   -- window if it is one, else the previous window (`wincmd p`),
                   -- else the first code window; nil if there is none
modified_files()   -- names of file buffers with unsaved changes
```

`code_win()` returning nil means the tab holds only terminals. Read recipes
then fail with "no code window in this tab", which is a real answer: the user
has no file open.

## Recipes

Each block is the body of the heredoc above.

### Cursor

```lua
local win = assert(code_win(), "no code window in this tab")
local buf = vim.api.nvim_win_get_buf(win)
local line, col = unpack(vim.api.nvim_win_get_cursor(win))
return {
	file = vim.api.nvim_buf_get_name(buf),
	line = line,
	col = col + 1,
	modified = vim.bo[buf].modified,
	text = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1],
}
```

### Last visual selection

Reads the `'<`/`'>` marks of the code window's buffer and the text between
them with `getregion()`. No motions, no registers. Returns `null` when the
buffer has never had a selection, which is a real answer and not an error.
`mode` comes from `visualmode()`, which is global (the last visual mode in any
buffer).

```lua
local buf = vim.api.nvim_win_get_buf((assert(code_win(), "no code window in this tab")))
local s, e = vim.api.nvim_buf_get_mark(buf, "<"), vim.api.nvim_buf_get_mark(buf, ">")
if s[1] == 0 then
	return nil
end
local mode = vim.fn.visualmode()
return {
	file = vim.api.nvim_buf_get_name(buf),
	start = { line = s[1], col = s[2] + 1 },
	["end"] = { line = e[1], col = e[2] + 1 },
	mode = mode,
	modified = vim.bo[buf].modified,
	text = vim.fn.getregion({ buf, s[1], s[2] + 1, 0 }, { buf, e[1], e[2] + 1, 0 }, { type = mode ~= "" and mode or "v" }),
}
```

### Open file buffers

```lua
return vim.iter(vim.fn.getbufinfo({ buflisted = 1 }))
	:filter(function(b) return vim.bo[b.bufnr].buftype == "" and b.name ~= "" end)
	:map(function(b) return { file = b.name, modified = b.changed == 1, lines = b.linecount } end)
	:totable()
```

### Push results to the quickfix list

The main agent → editor path. Prefer it over pasting long lists of paths and
line numbers into chat. `" "` pushes a **new** list, so earlier ones stay
reachable with `:colder`. Use absolute paths. It doesn't open the quickfix
window; the user does that.

```lua
vim.fn.setqflist({}, " ", {
	title = "semantic search: node allocation",
	items = {
		{ filename = "/abs/path/src/foo.zig", lnum = 42, col = 5, text = "why this line matters" },
	},
})
return vim.fn.getqflist({ title = 1, size = 1 })
```

### Open a file at a line

Opens in `code_win()`, or in a new split left of pi's terminal if the tab has
no code window. Focus stays where it is; the user moves over with `⌘h`. `:edit`
re-reads an unmodified file and fires `BufEnter`, so diff plugins recompute
their hunks. It raises instead of prompting if the window's buffer can't be
abandoned.

```lua
local path, line = "/abs/path/to/file.lua", 42
local win = code_win()
if not win then
	win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, { split = "left", win = 0 })
end
vim.api.nvim_win_call(win, function()
	vim.cmd.edit(vim.fn.fnameescape(path))
	vim.api.nvim_win_set_cursor(0, { line, 0 })
	vim.cmd("normal! zz")
end)
return { win = win, file = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) }
```

### Reload after something rewrote the working copy

`:checktime` with guard rails. A `jj edit`, rebase or branch switch rewrites
files under the editor. Every open buffer becomes a stale copy, and diff
plugins compute hunks against the wrong text.

- **Refuses, changing nothing, if any file buffer is modified.** `:checktime`
  on a dirty buffer either discards the user's edits or blocks on a prompt.
- Forces `autoread` for the duration and restores it even on failure.

```lua
local dirty = modified_files()
if #dirty > 0 then
	error("unsaved buffers, not reloading: " .. table.concat(dirty, ", "), 0)
end
local prior = vim.go.autoread
vim.go.autoread = true
local ok, err = pcall(vim.cmd.checktime)
vim.go.autoread = prior
assert(ok, err)
return vim.iter(vim.fn.getbufinfo({ buflisted = 1 }))
	:filter(function(b) return vim.bo[b.bufnr].buftype == "" and b.name ~= "" end)
	:map(function(b) return { file = b.name, lines = b.linecount } end)
	:totable()
```

## Stale reads: check before you read

The `read` tool reads **disk**. If the user has unsaved changes, you will
silently reason about code they no longer have. Before reading a file they are
likely editing, run `return modified_files()`. If it's listed, say so and read
the buffer (`nvim_buf_get_lines`) instead of the disk copy.

## Working directory: read before you change

The user may expect you to work in another folder through their session. A
directory change is invisible in the editor (no message, no statusline change),
so the report is the only feedback anyone gets. **Always read first:**

```lua
local win = code_win()
local buf = win and vim.api.nvim_win_get_buf(win)
local buf_local = buf and vim.fn.haslocaldir(-1, -1, buf) == 1
return {
	effective = buf_local and vim.fn.getcwd(-1, -1, buf) or vim.fn.getcwd(win or -1, 0),
	global = vim.fn.getcwd(-1, -1),
	tab = { dir = vim.fn.getcwd(-1, 0), ["local"] = vim.fn.haslocaldir(-1, 0) == 1 },
	window = win and { dir = vim.fn.getcwd(win), ["local"] = vim.fn.haslocaldir(win) == 1 },
	buffer = buf and { dir = vim.fn.getcwd(-1, -1, buf), ["local"] = buf_local },
	servery_original = vim.g.servery_original_cwd,
}
```

`effective` is what the code window's relative paths, `:find`, `:grep` and
pickers resolve against. `local: true` means that scope was set explicitly.
`window` and `buffer` are the code window's, not pi's terminal's, and are
absent when there is no code window. Don't use `nvim_win_call(win,
vim.fn.getcwd)` for `effective`: it ignores `:bcd`.

### Changing it

```lua
local scope, dir = "buffer", "/abs/path/to/repo" -- dir = vim.NIL unsets the scope
local cmd = ({ global = "cd", tab = "tcd", window = "lcd", buffer = "bcd" })[scope]
	or error("scope must be global, tab, window or buffer; got " .. tostring(scope), 0)
local unset = dir == vim.NIL
if unset and scope == "global" then
	error("the global scope has no unset; pass a directory", 0)
end
if not unset and (vim.fn.isabsolutepath(dir) == 0 or vim.fn.isdirectory(dir) == 0) then
	error("dir must be an absolute path to an existing directory; got " .. dir, 0)
end
local win = 0
if scope == "window" or scope == "buffer" then
	win = assert(code_win(), "no code window in this tab")
end
vim.api.nvim_win_call(win, function()
	vim.cmd({ cmd = cmd, args = unset and {} or { dir }, bang = unset })
end)
```

Then run the read recipe again and report the result.

| scope | Ex command | Who it moves | Sticky |
|---|---|---|---|
| `global` | `:cd` | the whole session, incl. its servery picker entry | — |
| `tab` | `:tcd` | every window in the tab; clears their `:lcd` | yes |
| `window` | `:lcd` | the code window | yes — new windows inherit it |
| `buffer` | `:bcd` | the code window's buffer only | no |

Pick by intent, and say which you used:

- **The user should follow you** into a new project: `global` (or `tab` if
  they keep one project per tab). servery then shows the session as
  `original ( current)`.
- **You need a root for your own work** without disturbing them: `buffer`.
  It's the narrowest scope and dies with the buffer.

None of these move pi's shell. Its cwd is its own.

**Narrow scopes shadow wider ones.** With a buffer-local directory set,
`global` succeeds and `effective` doesn't move. If a re-root looks like it did
nothing, read `effective`; don't re-issue the command. Unset the narrower scope
instead.

## Workflow: walking an MR commit by commit

The aim is a review in the user's editor, one commit at a time, where **the
gutter shows exactly one commit's changes** while you talk through it.

### Why the gutter looks empty by default

Diff plugins compare the buffer against the working-copy parent: `jj @-`, or
git `HEAD` (which *is* `@-` in a colocated repo). Committed work is part of
that baseline, so it shows **no signs at all**. That's the normal state, not a
broken setup.

### The lever: move the working copy, not the plugin

`jj edit <commit>` makes `@` *be* that commit, so `@-` is its parent and a
jj-aware diff source renders exactly that commit's hunks. Prefer this to
reconfiguring the user's plugin. Don't use `jj new <commit>`: it makes `@` a
child, so the gutter is empty.

### Before you start

1. `--sessions`: confirm `self` has `uis ≥ 1`.
2. Run the cwd read recipe. The session is often rooted elsewhere.
3. Run `return modified_files()`. Dirty buffers block the whole workflow.
4. `jj log -r @ -T 'change_id.short(8)'`. **Record this.** It's where you
   return to.

Use absolute paths in quickfix and open chunks rather than re-rooting. If the
user should follow you into the repo, `cd` the `global` scope, say so, and
restore it afterwards.

### Per commit

1. `jj edit <commit>`
2. The reload recipe. Every open buffer is now stale.
3. The open recipe on the first hunk. It re-reads the file and refreshes the
   gutter.
4. The quickfix recipe, titled `commit N/M - <subject>`, with one entry per
   hunk. Annotations say *why*, not what; the diff already says what.

Then talk it through and pause between commits. This is a conversation, not a
batch job.

### Cleanup: always

`jj edit <recorded change id>`, then reload, and restore the directory if you
moved it. A working copy left on an interior commit is a real hazard: the
user's next edit silently amends a reviewed commit. Restore it even if the
review is abandoned. Record the **change id**, not the commit id, since
rewrites invalidate the latter.

### When the diff itself is the artifact

If the plugin story is uncertain or the commit deletes files, write per-commit
patches and open those instead. Neovim highlights `.diff` natively.

```bash
jj diff -r <commit> --git > /tmp/review/N-<commit>-<slug>.diff
```

Quickfix entries can point *into* the patch file, so `:cnext` steps hunk to
hunk with your annotations attached.

## Status

Verified against throwaway headless sessions (a code window plus a terminal as
the current window, mirroring pi's layout) and read-only against the live
session:

- `rpc.lua`: chunks, `ARGS_JSON`, nil results, Lua and syntax errors,
  unserialisable results, every usage error, dead sockets, a 1s timeout
  against a session blocked in `vim.uv.sleep` (the session stays usable
  afterwards), and `--sessions` returning in ~1s with one blocked session
- recipes: cursor, selection, buffers, quickfix, open (with and without a
  code window; focus stays on the terminal), reload (dirty refusal, clean
  reload, `autoread` restored), and cwd/cd across all four scopes, unset and
  shadowing, checked against the directory seen after actually entering the
  window

Not built: draining marks the user sends from nvim, diagnostics, signs. See
[TODO.md](TODO.md).
