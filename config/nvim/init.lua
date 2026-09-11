-- Enable the bytecode cache before anything else, so the Lua modules sourced
-- by vim.pack.add() (plugin/ files) are cached too.
vim.loader.enable()

if vim.fn.has("nvim-0.12.3") ~= 1 then
	vim.notify("init.lua requires nvim >= 0.12.3 (vim.treesitter.select)", vim.log.levels.ERROR)
	return
end

-- =============================================================================
-- Options
-- =============================================================================

vim.opt.clipboard = "unnamedplus"
-- Over SSH (dev container) there is no clipboard tool, and nvim won't
-- auto-enable OSC 52 while 'clipboard' is set. Opt in manually, write-only:
-- yanks/cuts go to the host clipboard via the terminal; pastes use the local
-- register (avoids an OSC 52 read + permission prompt on every `p`).
if vim.env.SSH_TTY then
	local osc52 = require("vim.ui.clipboard.osc52")
	local function local_paste()
		return { vim.split(vim.fn.getreg('"'), "\n"), vim.fn.getregtype('"') }
	end
	vim.g.clipboard = {
		name = "OSC 52 (write-only)",
		copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
		paste = { ["+"] = local_paste, ["*"] = local_paste },
	}
end
vim.opt.signcolumn = "yes"
vim.opt.cursorline = true
vim.opt.winborder = "single"
vim.opt.mouse = "n"

-- Where jumps land. The vim.lsp.buf.definition() family honours this as of
-- 0.13: reuse an existing window showing the target, else open a vsplit.
vim.opt.switchbuf = { "useopen", "vsplit" }

-- Native LSP completion (replaces blink.cmp). 'fuzzy' enables fuzzy matching,
-- 'popup' shows the item's info in a floating window, 'preselect' honours the
-- server's CompletionItem.preselect hint.
vim.opt.completeopt = { "menuone", "preselect", "popup", "fuzzy" }
-- Pop the completion menu up as you type, no <C-x><C-o> needed. It is
-- buffer-local, so turn it back off in prompt buffers (snacks pickers etc.)
-- where an unprompted popup just fights with the picker's own list.
vim.opt.autocomplete = true
vim.api.nvim_create_autocmd("FileType", {
	pattern = { "snacks_picker_input", "snacks_input" },
	callback = function(args)
		vim.bo[args.buf].autocomplete = false
	end,
})

vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.wrap = true      -- Enable soft wrapping
vim.opt.linebreak = true -- Wrap at word boundaries

vim.opt.list = true
vim.opt.listchars = { tab = "→ ", trail = "·", nbsp = "␣", lead = "·" }

vim.opt.foldmethod = "expr"
vim.opt.foldlevelstart = 99
vim.opt.foldexpr = "v:lua.vim.treesitter.foldexpr()"

vim.opt.relativenumber = true
-- NOTE: 'indentexpr' is buffer-local, so setting it here (vim.bo == :setlocal)
-- would only ever apply to the startup buffer. It is set per buffer by the
-- FileType autocmd that starts treesitter (see "Treesitter" below).

vim.opt.ignorecase = true
vim.opt.smartcase = true

-- Pick up vifm's bundled vim plugin (syntax, ftdetect, ftplugin) from brew.
local vifm_rtp = (vim.env.HOMEBREW_PREFIX or "/opt/homebrew") .. "/opt/vifm/share/vifm/vim"
if vim.uv.fs_stat(vifm_rtp) then
	vim.opt.runtimepath:append(vifm_rtp)
end

-- =============================================================================
-- Plugins
-- =============================================================================
--
-- Always use this blog for documentation on how to use `vim.pack`: https://echasnovski.com/blog/2026-03-13-a-guide-to-vim-pack

-- Build hooks must be registered BEFORE vim.pack.add()
vim.api.nvim_create_autocmd("PackChanged", {
	callback = function(ev)
		local name, kind = ev.data.spec.name, ev.data.kind
		if name == "nvim-treesitter" and kind == "update" then
			if not ev.data.active then vim.cmd.packadd("nvim-treesitter") end
			vim.cmd("TSUpdate")
		end
	end,
})

vim.pack.add({
	-- Theme (loaded first so colorscheme is set before other plugins)
	"https://github.com/ellisonleao/gruvbox.nvim",
	"https://github.com/shortcuts/no-neck-pain.nvim",

	"https://github.com/wsdjeg/vim-fetch",
	"https://github.com/tpope/vim-surround",

	-- VCS
	"https://github.com/echasnovski/mini.diff",
	-- Own fork, on the branch that stacks the annotate tooltip fix on top of the
	-- log picker. Dev checkout lives in ~/build/git/jj.nvim.
	{ src = "https://github.com/whereistejas/jj.nvim", version = "fix-annotate-tooltip" },
	"https://github.com/esmuellert/codediff.nvim",
	"https://github.com/MunifTanjim/nui.nvim",

	-- Picker / QoL
	"https://github.com/folke/snacks.nvim",

	-- Treesitter
	"https://github.com/nvim-treesitter/nvim-treesitter",
	-- Markdown
	"https://github.com/MeanderingProgrammer/render-markdown.nvim",

	-- LSP
	"https://github.com/neovim/nvim-lspconfig",
})

-- =============================================================================
-- Functions
-- =============================================================================

-- Auto-detect jj repo: walk up from buffer path, stopping at cwd.
local function find_jj_repo()
	local cwd = vim.fn.getcwd()
	local dir = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p:h")
	while #dir >= #cwd do
		if vim.fn.isdirectory(dir .. "/.jj") == 1 then return dir end
		local parent = vim.fn.fnamemodify(dir, ":h")
		if parent == dir then break end
		dir = parent
	end
	return nil
end

-- cd into jj repo. If last arg names a repo dir under cwd, use that and
-- strip it from args. Otherwise detect from current buffer.
local function cd_to_jj_repo(args)
	if #args > 0 then
		local candidate = vim.fn.getcwd() .. "/" .. args[#args]
		if vim.fn.isdirectory(candidate .. "/.jj") == 1 then
			vim.cmd.cd(candidate)
			table.remove(args)
			return
		end
	end
	local repo = find_jj_repo()
	if repo then vim.cmd.cd(repo) end
end

-- Split a long signature line (params/fields) one element per line; used by
-- the LSP hover override below.
local function split_params(line)
	-- Find first ( or { and its matching closer
	local opos, open, close
	for i = 1, #line do
		local c = line:sub(i, i)
		if c == "(" or c == "{" then
			opos, open, close = i, c, c == "(" and ")" or "}"
			break
		end
	end
	if not opos then return end
	local depth, cpos = 0, nil
	for i = opos, #line do
		local c = line:sub(i, i)
		if c == open then depth = depth + 1 end
		if c == close then
			depth = depth - 1; if depth == 0 then
				cpos = i; break
			end
		end
	end
	if not cpos then return end

	-- Split inner text on top-level , or ; (respects nested brackets/generics)
	local inner = line:sub(opos + 1, cpos - 1)
	local parts, sep, d, buf = {}, ",", 0, {}
	for i = 1, #inner do
		local c = inner:sub(i, i)
		local prev = i > 1 and inner:sub(i - 1, i - 1) or ""
		if ("({["):find(c, 1, true) then
			d = d + 1
		elseif (")}]"):find(c, 1, true) then
			d = math.max(0, d - 1)
		elseif c == "<" and prev:match("[%w_]") then
			d = d + 1 -- generic <
		elseif c == ">" and d > 0 then
			d = d - 1 -- generic >
		elseif d == 0 and (c == "," or c == ";") then
			sep = c; parts[#parts + 1] = vim.trim(table.concat(buf)); buf = {}
			goto continue
		end
		buf[#buf + 1] = c
		::continue::
	end
	local tail = vim.trim(table.concat(buf))
	if tail ~= "" then parts[#parts + 1] = tail end
	if #parts <= 1 then return end

	-- Reassemble: one element per indented line
	local out = { line:sub(1, opos) }
	for j, p in ipairs(parts) do
		out[#out + 1] = "    " .. p .. (j < #parts and sep or "")
	end
	out[#out + 1] = line:sub(cpos)
	return out
end

-- Toggle all diagnostic display (virtual text/lines, underline, signs).
function _G.toggle_diagnostics()
	local cfg = vim.diagnostic.config()
	if cfg.virtual_text then
		vim.diagnostic.config({
			virtual_text = false,
			virtual_lines = false,
			underline = false,
			signs = false,
		})
	else
		vim.diagnostic.config({
			virtual_text = true,
			virtual_lines = true,
			underline = true,
			signs = true,
		})
	end
end

-- Copy the visual selection with context — relative path, line range, and the
-- enclosing LSP symbol path (e.g. Class.method) — to the clipboard.
local symbol_kind = vim.lsp.protocol.SymbolKind
local symbol_containers = {
	[symbol_kind.Class] = true,
	[symbol_kind.Method] = true,
	[symbol_kind.Function] = true,
	[symbol_kind.Constructor] = true,
	[symbol_kind.Struct] = true,
	[symbol_kind.Interface] = true,
	[symbol_kind.Module] = true,
	[symbol_kind.Namespace] = true,
	[symbol_kind.Enum] = true,
}

local function symbol_path(symbols, line, acc)
	acc = acc or {}
	for _, sym in ipairs(symbols) do
		local range = sym.range or (sym.location and sym.location.range)
		if range and range.start.line <= line and line <= range["end"].line then
			if symbol_containers[sym.kind] then acc[#acc + 1] = sym.name end
			if sym.children then symbol_path(sym.children, line, acc) end
		end
	end
	return acc
end

local function lsp_symbol_location(bufnr, line)
	if #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/documentSymbol" }) == 0 then
		return nil
	end
	local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
	local res = vim.lsp.buf_request_sync(bufnr, "textDocument/documentSymbol", params, 1000)
	if not res then return nil end
	for _, r in pairs(res) do
		if r.result and #r.result > 0 then
			local parts = symbol_path(r.result, line)
			if #parts > 0 then return table.concat(parts, ".") end
		end
	end
	return nil
end

local function copy_selection_with_context()
	local bufnr = vim.api.nvim_get_current_buf()
	local mode = vim.fn.mode()
	local p1, p2 = vim.fn.getpos("v"), vim.fn.getpos(".")
	local sline, eline = math.min(p1[2], p2[2]), math.max(p1[2], p2[2])

	local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":.")
	local text = table.concat(vim.fn.getregion(p1, p2, { type = mode }), "\n")
	local loc = lsp_symbol_location(bufnr, sline - 1)

	local header = string.format("%s:%d-%d", path, sline, eline)
	if loc then header = header .. string.format(" (%s)", loc) end

	local out = string.format("%s\n```%s\n%s\n```\n", header, vim.bo[bufnr].filetype, text)
	vim.fn.setreg("+", out)
	vim.notify("Copied: " .. header)
end

-- =============================================================================
-- Plugin setup
-- =============================================================================

-- Theme
vim.o.background = "dark"
vim.cmd("colorscheme gruvbox")

-- mini.diff — gutter change markers. Uses a jj-aware source that diffs the
-- buffer against jj's working-copy parent `@-`, so signs work in jj workspaces
-- (which have no per-workspace .git and thus break gitsigns). Falls back to the
-- built-in git source for repos without a .jj (pure-git checkouts).
local MiniDiff = require("mini.diff")

local function buf_jj_root(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" or vim.bo[bufnr].buftype ~= "" then return nil end
	local jj = vim.fs.find(".jj", { path = vim.fs.dirname(name), upward = true, type = "directory" })[1]
	return jj and vim.fs.dirname(jj) or nil
end

local function jj_set_ref(bufnr, root)
	local name = vim.api.nvim_buf_get_name(bufnr)
	vim.system(
		{ "jj", "file", "show", "-r", "@-", name },
		{ cwd = root, text = true },
		vim.schedule_wrap(function(obj)
			if not vim.api.nvim_buf_is_valid(bufnr) then return end
			-- non-zero exit => path absent in @- (new file): empty ref = all-added.
			MiniDiff.set_ref_text(bufnr, obj.code == 0 and (obj.stdout or "") or "")
		end)
	)
end

local jj_source = {
	name = "jj",
	attach = function(bufnr)
		local root = buf_jj_root(bufnr)
		if not root then return false end -- not a jj repo -> fall through to git source
		local group = vim.api.nvim_create_augroup("mini-diff-jj-" .. bufnr, { clear = true })
		vim.api.nvim_create_autocmd({ "BufWritePost", "BufEnter", "FocusGained" }, {
			group = group,
			buffer = bufnr,
			callback = function() jj_set_ref(bufnr, root) end,
		})
		jj_set_ref(bufnr, root)
	end,
	detach = function(bufnr)
		pcall(vim.api.nvim_del_augroup_by_name, "mini-diff-jj-" .. bufnr)
	end,
}

MiniDiff.setup({
	source = { jj_source, MiniDiff.gen_source.git() },
	view = {
		style = "sign",
		signs = { add = "┃", change = "┃", delete = "▁" },
	},
})

-- codediff.nvim — VSCode-style side-by-side diff viewer. It is git-based
-- (shells out to `git rev-parse`/`cat-file`), so it only works in git-colocated
-- jj repos; in a jj *workspace* (no per-worktree .git) it errors "not a git
-- repo". The "auto" backend below routes around that.
require("codediff").setup()

-- jj.nvim
require("jj").setup({
	-- Use the snacks picker for jj.nvim's status/file_history/conflict pickers
	-- (falls back to vim.ui.select when snacks is disabled).
	picker = {
		snacks = {},
	},
	diff = {
		-- "auto" (registered below): codediff's side-by-side view in git-colocated
		-- repos, else the jj-native backend (works in workspaces too). `d` in
		-- :J log dispatches through it.
		backend = "auto",
	},
	-- Open jj terminal windows (log/status) as a vertical split. splitright is
	-- unset (default off), so the split lands on the left.
	terminal = {
		window = {
			type = "vsplit",
		},
	},
	-- Open the describe/commit message editor as a vertical split too, so the
	-- whole jj.nvim UI stays vertical (v0.7.0 added configurable editor layouts).
	editor = {
		window = {
			type = "vsplit",
		},
	},
	cmd = {
		keymaps = {
			-- Aligned with jjui's `revisions` scope keybindings.
			log = {
				-- jjui parity
				diff = "d",
				describe = "<CR>",
				edit = "e",
				edit_immutable = "<M-e>",
				new = "n",
				abandon = "a",
				rebase = "r",
				squash = "<S-s>",
				split = "s",
				bookmark = "b",
				undo = "u",
				redo = "<S-u>",
				change_revset = "<S-l>",
				summary = "<S-k>",
				-- jj.nvim-only (no jjui log-scope equivalent)
				push = "<S-p>",
				push_all = "<C-p>",
				fetch = "f",
				open_pr = "o",
				open_pr_list = "<S-o>",
				quick_squash = "<C-s>",
				new_after = "<C-n>",
				new_after_immutable = "<S-n>",
				tag_set = "<S-t>",
				history = "<S-h>",
				select_next_revision = "gj",
				select_prev_revision = "gk",
			},
			summary_tooltip = {
				diff = "d",
				edit = "<CR>",
			},
		},
	},
})

-- "auto" diff backend: prefer codediff's side-by-side view (it's git-based),
-- falling back to the jj-native backend only when git can't back the diff.
-- Registered after jj.setup so the built-in codediff/native backends load first.
--
-- codediff shells out to git in a working dir. That's fine in a git-colocated
-- jj repo, but a jj *workspace* has no per-worktree .git, so codediff errors
-- "not a git repo". Trick: `jj git root` points at the shared colocated git
-- repo backing the workspace, and every workspace commit already lives in that
-- shared object store (verified). codediff's revision/explorer paths fall back
-- to the *cwd* git root (captured synchronously at command entry), so for a
-- workspace we run codediff with cwd temporarily set to that shared worktree
-- and its git calls resolve correctly.
local jjdiff = require("jj.diff")

-- Returns (worktree, colocated). `worktree` is a git working dir whose object
-- store holds this jj repo's commits, or nil if there's no git backing at all.
-- Memoized per jj root: the git backing of a given root can't change while
-- nvim is running, and the `jj git root` call is on a keypress path.
local jj_worktree_cache = {}

local function jj_git_worktree()
	local jj = vim.fs.find(".jj", { path = vim.fn.getcwd(), upward = true, type = "directory" })[1]
	if not jj then return nil, false end
	local root = vim.fs.dirname(jj)
	local cached = jj_worktree_cache[root]
	if cached then return cached[1], cached[2] end

	local function remember(wt, colocated)
		jj_worktree_cache[root] = { wt, colocated }
		return wt, colocated
	end

	if vim.fn.isdirectory(root .. "/.git") == 1 or vim.fn.filereadable(root .. "/.git") == 1 then
		return remember(root, true) -- colocated: the jj root is itself a git worktree
	end
	local ok, obj = pcall(function()
		return vim.system({ "jj", "git", "root" }, { cwd = root, text = true }):wait(2000)
	end)
	if ok and obj.code == 0 then
		local out = vim.trim(obj.stdout or "")
		if out ~= "" then
			local wt = vim.fn.fnamemodify(out, ":h")                     -- dirname of .../repo/.git => .../repo
			if vim.fn.isdirectory(wt) == 1 then return remember(wt, false) end -- workspace: shared worktree
		end
	end
	return remember(nil, false)
end

-- Run fn with cwd temporarily set to `dir`. codediff captures cwd synchronously
-- at command entry, so restoring immediately after is safe.
local function with_cwd(dir, fn)
	local prev = vim.fn.getcwd()
	pcall(vim.cmd.lcd, vim.fn.fnameescape(dir))
	local ok, err = pcall(fn)
	pcall(vim.cmd.lcd, vim.fn.fnameescape(prev))
	if not ok then vim.notify("jj auto-diff: " .. tostring(err), vim.log.levels.ERROR) end
end

local function auto(kind)
	return function(o)
		o = o or {}
		local wt, colocated = jj_git_worktree()
		-- "current" diffs the live working-copy file; codediff can only reach it
		-- when git backs the worktree in place (colocated). With no git backing at
		-- all, use the jj-native backend (it does side-by-side via `jj file show`).
		if not wt or (kind == "current" and not colocated) then
			o.backend = "native"
			return jjdiff.open(kind, o)
		end
		o.backend = "codediff"
		if colocated then return jjdiff.open(kind, o) end
		with_cwd(wt, function() jjdiff.open(kind, o) end)
	end
end

jjdiff.register_backend("auto", {
	diff_current = auto("current"),
	show_revision = auto("revision"),
	diff_revisions = auto("revisions"),
	diff_history_revisions = auto("history"),
})

-- jj.nvim hardcodes `:J log` to --limit 20; bump it unless the caller overrode.
local jj_log_module = require("jj.cmd.log")
local orig_log = jj_log_module.log
jj_log_module.log = function(opts)
	opts = opts or {}
	if not opts.raw_flags and not opts.limit then
		opts.limit = 9999
	end
	return orig_log(opts)
end
require("jj.cmd").log = jj_log_module.log

-- Wrap jj.cmd.j so the original :J command (with completion) stays intact.
local jj_cmd = require("jj.cmd")
local orig_j = jj_cmd.j
jj_cmd.j = function(args)
	if type(args) == "string" then args = vim.split(args, "%s+") end
	cd_to_jj_repo(args)
	return orig_j(args)
end

-- mermaid-cli (mmdc) drives a headless Chrome via puppeteer, but Homebrew's
-- mmdc pins a chrome-headless-shell version that is usually absent from
-- ~/.cache/puppeteer. Point it at whatever build IS cached, via a generated
-- puppeteer config file. Returns nil if none is cached (then mmdc's own
-- version resolution applies, and mermaid rendering just fails silently).
local function mermaid_puppeteer_config()
	local bins = vim.fn.glob(vim.fn.expand("~/.cache/puppeteer/chrome-headless-shell/*/*/chrome-headless-shell"),
		false, true)
	if #bins == 0 then return nil end
	table.sort(bins)
	local cfg = vim.fs.joinpath(vim.fn.stdpath("cache"), "mermaid-puppeteer.json")
	vim.fn.writefile({ vim.json.encode({ executablePath = bins[#bins] }) }, cfg)
	return cfg
end

-- snacks (picker + explorer + image)
-- Guarded: snacks.nvim throws "already setup" on a second setup() call, which
-- would abort `:source $MYVIMRC`.
if not vim.g.snacks_did_setup then
	vim.g.snacks_did_setup = true
	require("snacks").setup({
		picker = {
			enabled = true,
			icons = {
				files = { enabled = false }, -- hide file-type icons
			},
			win = {
				-- Drop line-number/sign gutter in the preview pane.
				preview = { minimal = true },
			},
		},
		explorer = { enabled = true },
		-- Inline images / mermaid diagrams via the kitty graphics protocol.
		-- Mermaid fences need `mmdc` (npm: @mermaid-js/mermaid-cli).
		image = {
			enabled = true,
			convert = {
				mermaid = function()
					local theme = vim.o.background == "light" and "neutral" or "dark"
					local args = { "-i", "{src}", "-o", "{file}", "-b", "transparent", "-t", theme, "-s", "{scale}" }
					local cfg = mermaid_puppeteer_config()
					if cfg then vim.list_extend(args, { "-p", cfg }) end
					return args
				end,
			},
		},
	})
end

-- no-neck-pain (centered layout)
require("no-neck-pain").setup({ width = 120 })

-- render-markdown (in-buffer markdown rendering)
require("render-markdown").setup({})

-- Treesitter
require("nvim-treesitter").setup()
require("nvim-treesitter.install").install({ "typescript", "tsx", "lua", "rust", "ocaml", "json", "html", "css", "python",
	"ruby", "bash" })

-- nvim-treesitter (main branch) does NOT enable highlighting: Nvim only
-- auto-starts it via runtime ftplugins for the filetypes whose parser it
-- bundles (lua, markdown, query, help, diff, ...). Without this, every parser
-- installed above sits unused and buffers fall back to regex 'syntax'.
-- Also point 'indentexpr' at treesitter for languages that ship an indents
-- query; otherwise the runtime ftplugin's indentexpr (e.g. GetRustIndent())
-- stays in place.
vim.api.nvim_create_autocmd("FileType", {
	group = vim.api.nvim_create_augroup("treesitter-start", { clear = true }),
	callback = function(ev)
		local lang = vim.treesitter.language.get_lang(ev.match) or ev.match
		-- Skip if a runtime ftplugin already started a highlighter for this buffer.
		if not vim.treesitter.highlighter.active[ev.buf] then
			if not pcall(vim.treesitter.start, ev.buf, lang) then return end
		end
		if vim.treesitter.query.get(lang, "indents") then
			vim.bo[ev.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
		end
	end,
})

-- =============================================================================
-- LSP
-- =============================================================================

-- Reformat long param/field lists in hover: put each element on its own line.
-- In 0.12, vim.lsp.buf.hover() calls open_floating_preview directly (not via
-- handlers), so this monkey-patch is the correct interception point.
local orig_open_float = vim.lsp.util.open_floating_preview
function vim.lsp.util.open_floating_preview(contents, syntax, opts, ...)
	local formatted = {}
	for _, ln in ipairs(contents) do
		local split = #ln > 80 and split_params(ln)
		if split then
			vim.list_extend(formatted, split)
		else
			formatted[#formatted + 1] = ln
		end
	end
	return orig_open_float(formatted, syntax, opts, ...)
end

-- nvim-lspconfig ships an `lsp/<name>.lua` for every server enabled below.
-- `vim.lsp.config(name, {...})` MERGES with that config chain, whereas
-- assigning `vim.lsp.config.name = {...}` REPLACES it — which silently threw
-- away lspconfig's smarter `cmd` (local node_modules resolution), `root_dir`
-- (monorepo/deno detection), `handlers`, `commands` and `get_language_id`.
-- So only the actual deltas live here; lua_ls, ts_ls, ocamllsp, eslint and
-- marksman need no overrides at all.

vim.lsp.config("ruby_lsp", {
	init_options = {
		formatter = "standard",
		linters = { "standard" },
	},
})

vim.lsp.config("ruff", {
	init_options = {
		settings = {
			fixAll = false,
			organizeImports = false,
		},
	},
})

-- Host: bun-installed (needs `bun` to run, no system node). Container: the
-- Nix-wrapped binary on PATH bundles its own node, so lspconfig's default cmd
-- is already right.
local bun_bashls = vim.env.HOME .. "/.bun/bin/bash-language-server"
if vim.uv.fs_stat(bun_bashls) then
	vim.lsp.config("bashls", { cmd = { "bun", bun_bashls, "start" } })
end

local ty_extra_paths = {}
for _, p in ipairs({
	vim.fn.expand("~/build/git/wst_core/python"),
	vim.fn.expand("~/build/git/wst_master"),
	vim.fn.expand("~/build/git/tornado-openapi3"),
	"/workspace/wst_core/python",
	"/workspace/wst_master",
	"/workspace/tornado-openapi3",
}) do
	if vim.fn.isdirectory(p) == 1 then table.insert(ty_extra_paths, p) end
end

vim.lsp.config("ty", {
	settings = {
		ty = {
			configuration = {
				environment = {
					["extra-paths"] = ty_extra_paths,
				},
			},
		},
	},
})

vim.lsp.enable("lua_ls")
vim.lsp.enable("rust_analyzer")
vim.lsp.enable("ts_ls")
vim.lsp.enable("eslint")
vim.lsp.enable("ocamllsp")
vim.lsp.enable("ruby_lsp")
vim.lsp.enable("ruff")
vim.lsp.enable("ty")
vim.lsp.enable("bashls")
vim.lsp.enable("marksman")
vim.lsp.enable("zls")

-- Diagnostics
vim.diagnostic.config({
	virtual_text = true,
	virtual_lines = true,
})

-- =============================================================================
-- Keymaps
-- =============================================================================

-- General
-- Go to definition via tag jump: uses vim.lsp.tagfunc when a server is
-- attached (LSP first, ctags fallback), else a plain tag-file lookup.
-- Global so it's present regardless of LspAttach timing. Jumplist/tagstack native.
vim.keymap.set("n", "gd", "<C-]>", { desc = "Go to definition (LSP + ctags fallback)" })

vim.keymap.set("n", "0", "^", { desc = "First non-blank character" })
vim.keymap.set("n", "9", "$", { desc = "End of line" })
vim.keymap.set("n", "j", "gj", { desc = "Down (display line)" })
vim.keymap.set({ "n", "x" }, ";", ":", { noremap = true, desc = "Command-line mode" })

-- Native completion popup: <Tab>/<S-Tab> cycle items, <CR> accepts the
-- selected item (plain <CR> otherwise, since completeopt has 'noselect').
vim.keymap.set("i", "<Tab>", function()
	return vim.fn.pumvisible() == 1 and "<C-n>" or "<Tab>"
end, { expr = true, desc = "Next completion item / <Tab>" })
vim.keymap.set("i", "<S-Tab>", function()
	return vim.fn.pumvisible() == 1 and "<C-p>" or "<S-Tab>"
end, { expr = true, desc = "Prev completion item / <S-Tab>" })
vim.keymap.set("i", "<CR>", function()
	if vim.fn.pumvisible() == 1 then
		local selected = vim.fn.complete_info({ "selected" }).selected
		return selected ~= -1 and "<C-y>" or "<C-e><CR>"
	end
	return "<CR>"
end, { expr = true, desc = "Accept completion / newline" })

-- Treesitter node selection (nvim 0.12.3+):
--   <up>/<down> expand to parent / shrink to child (normal + visual)
--   <left>/<right> select prev / next sibling (visual only)
vim.keymap.set({ "n", "x" }, "<up>", function() vim.treesitter.select("parent", vim.v.count1) end,
	{ desc = "Expand selection to parent node" })
vim.keymap.set({ "n", "x" }, "<down>", function() vim.treesitter.select("child", vim.v.count1) end,
	{ desc = "Shrink selection to child node" })
vim.keymap.set("x", "<left>", function() vim.treesitter.select("prev", vim.v.count1) end,
	{ desc = "Select previous sibling node" })
vim.keymap.set("x", "<right>", function() vim.treesitter.select("next", vim.v.count1) end,
	{ desc = "Select next sibling node" })

-- Copy selection + context (path:line-range (Symbol.path)) to the clipboard
vim.keymap.set("x", "Y", copy_selection_with_context,
	{ desc = "Copy selection with path/range/symbol context" })

-- Window navigation — move between splits in every mode (insert/visual/terminal too).
-- <Cmd> runs wincmd without leaving the current mode. Uses ⌘+letters so the
-- base-layer ⌘ home-row mod (hold A → cmd+hjkl) drives splits, leaving arrows
-- free for macOS text navigation (opt/cmd+arrow).
for key, desc in pairs({
	h = "Focus split left",
	j = "Focus split down",
	k = "Focus split up",
	l = "Focus split right",
}) do
	vim.keymap.set({ "n", "i", "v", "t" }, "<D-" .. key .. ">", "<Cmd>wincmd " .. key .. "<CR>", { desc = desc })
end

-- Move splits — ⌘-shift-hjkl (mirrors focus; like AeroSpace alt-shift-hjkl).
for key, desc in pairs({
	H = "Move split left",
	J = "Move split down",
	K = "Move split up",
	L = "Move split right",
}) do
	vim.keymap.set({ "n", "i", "v", "t" }, "<D-S-" .. key:lower() .. ">", "<Cmd>wincmd " .. key .. "<CR>",
		{ desc = desc })
end

-- Double-<Tab> cycles to the next window/split.
vim.keymap.set("n", "<Tab><Tab>", "<C-w>w", { desc = "Cycle to next window" })

-- Tabs — switch to tab N in every mode (insert/visual/terminal too).
-- <Cmd> runs the command without leaving the current mode.
for i = 1, 4 do
	vim.keymap.set({ "n", "i", "v", "t" }, "<D-" .. i .. ">", "<Cmd>tabnext " .. i .. "<CR>",
		{ desc = "Go to tab " .. i })
end

-- Tab prev/next — mirror AeroSpace's alt-[ / alt-] for workspaces.
vim.keymap.set({ "n", "i", "v", "t" }, "<D-[>", "<Cmd>tabprevious<CR>", { desc = "Previous tab" })
vim.keymap.set({ "n", "i", "v", "t" }, "<D-]>", "<Cmd>tabnext<CR>", { desc = "Next tab" })

-- Quickfix prev/next — wraps at the ends instead of erroring with E553.
local function qf_step(forward)
	if vim.fn.getqflist({ size = 0 }).size == 0 then
		return
	end
	if not pcall(vim.cmd, forward and "cnext" or "cprevious") then
		vim.cmd(forward and "cfirst" or "clast")
	end
end
vim.keymap.set("n", "<C-n>", function()
	qf_step(true)
end, { desc = "Next quickfix item" })
vim.keymap.set("n", "<C-p>", function()
	qf_step(false)
end, { desc = "Previous quickfix item" })

-- Terminal buffers: no line numbers, sign column, or listchars.
local function term_ui()
	vim.opt_local.number = false
	vim.opt_local.relativenumber = false
	vim.opt_local.list = false
	vim.opt_local.signcolumn = "no"
end
vim.api.nvim_create_autocmd("TermOpen", {
	group = vim.api.nvim_create_augroup("term-ui", { clear = true }),
	callback = term_ui,
})
-- Re-strip terminal windows after (re)sourcing, since :set clobbers the current
-- window's local options.
vim.api.nvim_create_autocmd("SourcePost", {
	group = "term-ui",
	callback = function()
		if vim.bo.buftype == "terminal" then
			term_ui()
		end
	end,
})

-- Terminal — double <Esc> leaves terminal mode (single <Esc> still reaches the program).
vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-n>", { desc = "Exit terminal mode" })

-- Git diff hunks (mini.diff): [h / ]h jump to prev/next hunk, [H / ]H first/last;
-- gh applies a hunk (also a hunk textobject), gH resets one to the @- version.

-- jj.nvim
vim.keymap.set("n", "<space>jj", "<cmd>J log<CR>", { desc = "jj log (jj.nvim)" })
-- Diff the working copy against @- in codediff (`d` in :J log diffs a change).
vim.keymap.set("n", "<space>jd", function()
	require("jj.diff").diff_current({ rev = "@-" })
end, { desc = "jj diff working copy vs @- (codediff)" })
-- jj.nvim pickers (snacks-backed)
vim.keymap.set("n", "<space>jl", function() require("jj.picker").log({ revset = "all()" }) end,
	{ desc = "jj picker: log (all)" })
vim.keymap.set("n", "<space>js", function() require("jj.picker").status() end, { desc = "jj picker: status" })
vim.keymap.set("n", "<space>jh", function() require("jj.picker").file_history() end, { desc = "jj picker: file history" })
vim.keymap.set("n", "<space>jc", function() require("jj.picker").conflict() end, { desc = "jj picker: conflicts" })
-- Takes over the built-in `U` (undo-line); `u`/<C-r> cover undo/redo.
vim.keymap.set("n", "U", function() require("jj.annotate").line() end, { desc = "jj annotate line (tooltip)" })

-- snacks picker
vim.keymap.set("n", "<space>t", function() Snacks.picker.pickers() end, { desc = "Pickers" })
vim.keymap.set("n", "<space>B", function() Snacks.picker.buffers() end, { desc = "Buffers" })
vim.keymap.set("n", "<space>f", function() Snacks.picker.files() end, { desc = "Find files" })
vim.keymap.set("n", "<space>F", function() Snacks.picker.files({ hidden = true, ignored = true }) end,
	{ desc = "Find files (hidden + ignored)" })
vim.keymap.set("n", "?", function() Snacks.picker.grep() end, { desc = "Live grep" })
vim.keymap.set("n", "<space><space>", function() Snacks.picker.resume() end, { desc = "Resume last picker" })
vim.keymap.set("n", "<space>r", function() Snacks.picker.lsp_references() end, { desc = "LSP references" })
vim.keymap.set("n", "<space>i", function() Snacks.picker.lsp_implementations() end, { desc = "LSP implementations" })
vim.keymap.set("n", "<space>d", function() Snacks.picker.lsp_definitions() end, { desc = "LSP definitions" })
vim.keymap.set("n", "<space>o", function() Snacks.picker.lsp_symbols() end, { desc = "Document symbols" })
vim.keymap.set("n", "<space>O", function()
	vim.lsp.buf.document_symbol({
		on_list = function(opts)
			vim.fn.setloclist(0, {}, " ", opts)
			vim.cmd("vert leftabove lopen 40")
		end,
	})
end, { desc = "Document symbols (left split)" })
vim.keymap.set("n", "<space>m", function() Snacks.picker.diagnostics() end, { desc = "Diagnostics" })
vim.keymap.set("n", "M", vim.diagnostic.open_float, { desc = "Line diagnostics (float)" })
vim.keymap.set("n", "<space>k", function() Snacks.picker.keymaps() end, { desc = "Keymaps" })
vim.keymap.set("n", "<space>c", function() Snacks.explorer({ cwd = vim.fn.expand("%:p:h") }) end,
	{ desc = "File explorer (current file dir)" })

-- Layout
vim.keymap.set("n", "<space>g", "<cmd>NoNeckPain<CR>", { desc = "Toggle centered layout" })

-- Terminal
vim.keymap.set("t", "<S-Esc>", [[<C-\><C-n>]], { desc = "Exit terminal mode" })

-- =============================================================================
-- Autocommands
-- =============================================================================

vim.api.nvim_create_autocmd("LspAttach", {
	group = vim.api.nvim_create_augroup("lsp", { clear = true }),
	callback = function(args)
		local client = vim.lsp.get_client_by_id(args.data.client_id)
		if not client then return end

		-- Native LSP completion (replaces blink.cmp): autotrigger the popup.
		if client:supports_method("textDocument/completion") then
			vim.lsp.completion.enable(true, client.id, args.buf, { autotrigger = true })
		end

		-- LspAttach fires again on every :edit of the buffer, so an ungrouped
		-- buffer-local BufWritePre autocmd accumulates one copy per attach and
		-- formatting then runs several times per write. Keep it in a group keyed
		-- by buffer+client, cleared on re-attach.
		local group = vim.api.nvim_create_augroup(
			("lsp-format-%d-%s"):format(args.buf, client.name), { clear = true })

		if client.name == "eslint" then
			vim.api.nvim_create_autocmd("BufWritePre", {
				group = group,
				buffer = args.buf,
				callback = function()
					client:request_sync("workspace/executeCommand", {
						command = "eslint.applyAllFixes",
						arguments = { {
							uri = vim.uri_from_bufnr(args.buf),
							version = vim.lsp.util.buf_versions[args.buf],
						} },
					}, 3000, args.buf)
				end,
			})
			-- Only format if the server supports it, and skip LSPs where another tool owns formatting (eslint for TS, ruff/ty for Python)
		elseif client:supports_method("textDocument/formatting")
			and client.name ~= "ts_ls" and client.name ~= "ruff" and client.name ~= "ty" then
			vim.api.nvim_create_autocmd("BufWritePre", {
				group = group,
				buffer = args.buf,
				callback = function()
					vim.lsp.buf.format({
						async = false,
						bufnr = args.buf,
						id = client.id,
					})
				end,
			})
		end
	end,
})
