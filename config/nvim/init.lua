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
-- 0.13: reuse an existing window showing the target, else use the current one.
vim.opt.switchbuf = { "useopen" }

-- Native LSP completion (replaces blink.cmp). 'fuzzy' enables fuzzy matching,
-- 'popup' shows the item's info in a floating window, 'preselect' honours the
-- server's CompletionItem.preselect hint.
vim.opt.completeopt = { "menuone", "preselect", "popup", "fuzzy" }
-- Pop the completion menu up as you type, no <C-x><C-o> needed. It is
-- buffer-local, so turn it back off in prompt buffers (snacks pickers etc.)
-- where an unprompted popup just fights with the picker's own list.
vim.opt.autocomplete = true
vim.opt.autocompletedelay = 300
vim.opt.pumheight = 10
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
	"https://github.com/folke/which-key.nvim",

	-- VCS
	"https://github.com/echasnovski/mini.diff",
	"https://github.com/NicolasGB/jj.nvim",
	"https://github.com/lewis6991/gitsigns.nvim",

	-- Picker / QoL
	"https://github.com/folke/snacks.nvim",
	{ src = "https://github.com/whereistejas/servery.nvim", version = "session-titles" },

	-- Treesitter
	"https://github.com/nvim-treesitter/nvim-treesitter",
	"https://github.com/nvim-treesitter/nvim-treesitter-textobjects",

	-- Markdown
	"https://github.com/MeanderingProgrammer/render-markdown.nvim",

	-- LSP
	"https://github.com/neovim/nvim-lspconfig",
})

-- =============================================================================
-- Functions
-- =============================================================================

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
vim.o.background = "light"
vim.cmd("colorscheme gruvbox")

-- mini.diff — gutter change markers. Uses a jj-aware source that diffs the
-- buffer against jj's working-copy parent `@-`, so signs work in jj workspaces
-- (which have no per-workspace .git and thus break gitsigns). Falls back to the
-- built-in git source for repos without a .jj (pure-git checkouts).
local MiniDiff = require("mini.diff")

local function buf_jj_root(bufnr)
	if vim.api.nvim_buf_get_name(bufnr) == "" or vim.bo[bufnr].buftype ~= "" then return nil end
	return vim.fs.root(bufnr, ".jj")
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

-- jj.nvim
require("jj").setup()

-- gitsigns — only for inline blame of the cursor line; mini.diff owns the gutter.
require("gitsigns").setup({
	signcolumn = false,
	current_line_blame = true,
})

-- which-key (popup of pending keymaps)
-- Plain-text key names instead of the default Nerd Font glyphs.
local wk_keys = {
	Up = "Up", Down = "Down", Left = "Left", Right = "Right",
	C = "C-", M = "M-", D = "D-", S = "S-",
	CR = "CR", Esc = "Esc", NL = "NL", BS = "BS", Space = "Space", Tab = "Tab",
	ScrollWheelDown = "ScrollWheelDown", ScrollWheelUp = "ScrollWheelUp",
}
for i = 1, 12 do wk_keys["F" .. i] = "F" .. i end
require("which-key").setup({
	preset = "helix",
	sort = { "group", "local", "order", "alphanum", "mod" }, -- groups always last
	icons = { mappings = false, separator = "", keys = wk_keys },
})

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
			sources = {
				-- <space>p: hide the git/GitHub pickers, list jj.nvim's pickers instead.
				pickers = {
					finder = function(opts, ctx)
						local items = vim.tbl_filter(function(item)
							return not item.text:match("^git_") and not item.text:match("^gh_")
						end, require("snacks.picker.source.meta").pickers(opts, ctx))
						local file = vim.api.nvim_get_runtime_file("lua/jj/picker.lua", false)[1]
						for _, name in ipairs({ "status", "file_history", "conflict", "conflict_sections" }) do
							table.insert(items, {
								text = "jj_" .. name,
								jj = name,
								file = file,
								search = ("/^function M\\.%s("):format(name),
							})
						end
						table.sort(items, function(a, b) return a.text < b.text end)
						return items
					end,
					confirm = function(picker, item)
						picker:close()
						if not item then return end
						vim.schedule(function()
							if item.jj then require("jj.picker")[item.jj]() else Snacks.picker(item.text) end
						end)
					end,
				},
				lsp_workspace_symbols = {
					sort = function(a, b)
						if a.file ~= b.file then return a.file < b.file end
						return a.pos[1] < b.pos[1]
					end,
				},
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

-- servery (jump between per-directory nvim sessions)
require("servery").setup({
	dirs = function()
		local out = {}
		for _, root in ipairs({ "~/build", "~/build/git" }) do
			root = vim.fs.normalize(root)
			for name, type in vim.fs.dir(root) do
				if type == "directory" then table.insert(out, vim.fs.joinpath(root, name)) end
			end
		end
		return out
	end,
	ui = { provider = "snacks" },
})

-- Session switcher: servery sessions/dirs first, then every folder under
-- ~/build streamed in from fd (gitignore-aware). Snacks fuzzy-ranks as you
-- type (score, then shortest path) and only renders the visible rows.
local function servery_pick()
	local servery = require("servery")
	local icons = servery.get_cfg().ui.icons
	local root = vim.fs.normalize("~/build")
	local seen = {}
	Snacks.picker.pick({
		source = "servery",
		title = "Switch Nvim Session",
		layout = { preview = false },
		finder = {
			function()
				seen = {}
				local items = {}
				for _, sv in ipairs(servery.get_picker_items()) do
					if not seen[sv.cwd] then
						seen[sv.cwd] = true
						local dir, title = vim.fn.fnamemodify(sv.cwd, ":~"), sv:title()
						items[#items + 1] = { text = title and (dir .. " " .. title) or dir, dir = dir, title = title, path = sv.cwd, sv = sv }
					end
				end
				return items
			end,
			function(_, ctx)
				return require("snacks.picker.source.proc").proc(ctx:opts({
					cmd = vim.fn.exepath("fd") ~= "" and "fd" or vim.fs.normalize("~/.pi/agent/bin/fd"),
					args = { "--type", "d", "--absolute-path", "--color", "never", ".", root },
					transform = function(item)
						local dir = item.text:gsub("/$", "")
						if seen[dir] then return false end
						item.path = dir
						item.text = vim.fn.fnamemodify(dir, ":~")
					end,
				}), ctx)
			end,
		},
		format = function(item)
			local sv = item.sv
			if not sv then return { { icons.inactive, "ServeryIconInactive" }, { "  " }, { item.text } } end
			local status = sv:status()
			return {
				{ sv:icon(), "ServeryIcon" .. status },
				{ "  " },
				{ item.dir, "ServeryLine" .. status },
				{ item.title and ("  " .. item.title) or "", "ServeryTitle" },
				{ "  " },
				{ sv:time_since_active() or "", "ServeryTime" },
			}
		end,
		confirm = function(picker, item)
			if not item then return end
			if item.sv then item.sv:switch() else servery.switch({ dir = item.path }) end
			picker:close()
		end,
	})
end

-- no-neck-pain (centered layout)
require("no-neck-pain").setup({ width = 120 })

-- render-markdown (in-buffer markdown rendering)
require("render-markdown").setup({ enabled = false })

-- Treesitter
require("nvim-treesitter").setup()
require("nvim-treesitter.install").install({ "typescript", "tsx", "lua", "rust", "ocaml", "json", "html", "css", "python",
	"ruby", "bash" })

-- Treesitter text objects: language-aware af/if (function) and ac/ic (class,
-- which also covers Rust struct/enum/trait/impl). Mappings live with the other
-- treesitter keymaps below.
require("nvim-treesitter-textobjects").setup({
	select = { lookahead = true },
})

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
-- Gated on focus_id: vim.lsp.buf.hover() (and the hover handler) set it to
-- "textDocument/hover", while signature help uses its own method id and
-- diagnostic floats set none — so those floats pass through untouched.
local orig_open_float = vim.lsp.util.open_floating_preview
function vim.lsp.util.open_floating_preview(contents, syntax, opts, ...)
	if not (opts and opts.focus_id == "textDocument/hover") then
		return orig_open_float(contents, syntax, opts, ...)
	end
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

vim.lsp.config("rust_analyzer", {
	settings = { ["rust-analyzer"] = { workspace = { symbol = { search = { limit = 10000 } } } } },
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

-- rust-analyzer's macro expansion is a custom request
-- (`rust-analyzer/expandMacro`), not part of the LSP spec, so nothing calls it
-- by default. Register it as a client-side command: nvim resolves Command-style
-- code actions against client.commands / vim.lsp.commands before falling back
-- to workspace/executeCommand, so the `gra` menu can offer it as a pseudo code
-- action (see the gra mapping in Keymaps).
vim.lsp.commands["rust-analyzer.expandMacro"] = function(cmd, ctx)
	local client = assert(vim.lsp.get_client_by_id(ctx.client_id))
	client:request("rust-analyzer/expandMacro", cmd.arguments[1], function(err, result)
		if err or not result then
			vim.notify("expandMacro: " .. (err and err.message or "no macro under the cursor"),
				vim.log.levels.WARN)
			return
		end
		vim.cmd("vnew")
		local buf = vim.api.nvim_get_current_buf()
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].filetype = "rust"
		vim.api.nvim_buf_set_name(buf, "macro-expansion://" .. result.name)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(result.expansion, "\n"))
		vim.bo[buf].modifiable = false
	end, ctx.bufnr)
end

-- Diagnostics
vim.diagnostic.config({
	virtual_text = true,
	virtual_lines = { current_line = true },
})

-- =============================================================================
-- Keymaps
-- =============================================================================

-- General
-- Go to definition via tag jump: uses vim.lsp.tagfunc when a server is
-- attached (LSP first, ctags fallback), else a plain tag-file lookup.
-- Global so it's present regardless of LspAttach timing. Jumplist/tagstack native.
vim.keymap.set("n", "gd", "<C-]>", { desc = "Go to definition (LSP + ctags fallback)" })

-- Default LSP code-action map, plus an "Expand macro recursively" entry in
-- buffers with rust_analyzer attached. vim.lsp.buf.code_action() offers no hook
-- for extra items, so wrap vim.ui.select for the duration of the call and
-- append one; the position is captured now, when the cursor is still on the
-- macro call.
vim.keymap.set({ "n", "x" }, "gra", function()
	local client = vim.lsp.get_clients({ bufnr = 0, name = "rust_analyzer" })[1]
	if not client then return vim.lsp.buf.code_action() end

	local extra = {
		action = {
			title = "Expand macro recursively",
			command = "rust-analyzer.expandMacro",
			arguments = { vim.lsp.util.make_position_params(0, client.offset_encoding) },
		},
		ctx = { bufnr = vim.api.nvim_get_current_buf(), client_id = client.id },
	}
	local orig_select = vim.ui.select
	local function restore()
		if vim.ui.select ~= orig_select then vim.ui.select = orig_select end
	end
	vim.ui.select = function(items, opts, on_choice)
		restore()
		if opts and opts.kind == "codeaction" then table.insert(items, extra) end
		return orig_select(items, opts, on_choice)
	end
	-- code_action() returns early, before vim.ui.select, when every server
	-- reports no actions — that would leave the wrapper installed.
	vim.defer_fn(restore, 2000)

	vim.lsp.buf.code_action()
end, { desc = "Code actions (+ Rust macro expansion)" })

vim.keymap.set("n", "0", "^", { desc = "First non-blank character" })
vim.keymap.set("n", "9", "$", { desc = "End of line" })
vim.keymap.set("n", "j", "gj", { desc = "Down (display line)" })
vim.keymap.set("n", "k", "gk", { desc = "Up (display line)" })
vim.keymap.set({ "n", "x" }, ";", ":", { noremap = true, desc = "Command-line mode" })

-- Native completion popup: <Tab>/<S-Tab> cycle items, <CR> accepts the
-- selected item (plain <CR> when nothing is selected).
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
vim.keymap.set("x", "<S-right>", function() vim.treesitter.select("extend_next", vim.v.count1) end,
	{ desc = "Extend selection over next sibling node" })
vim.keymap.set("x", "<S-left>", function() vim.treesitter.select("extend_prev", vim.v.count1) end,
	{ desc = "Extend selection over previous sibling node" })

-- Treesitter text objects (nvim-treesitter-textobjects):
--   af/if function, ac/ic class (Rust: struct/enum/trait/impl)
--   ]f/[f, ]c/[c jump to next/previous function or class start
local ts_select = require("nvim-treesitter-textobjects.select")
local ts_move = require("nvim-treesitter-textobjects.move")
for lhs, query in pairs({
	["af"] = "@function.outer",
	["if"] = "@function.inner",
	["ac"] = "@class.outer",
	["ic"] = "@class.inner",
}) do
	vim.keymap.set({ "x", "o" }, lhs, function() ts_select.select_textobject(query, "textobjects") end,
		{ desc = "Select " .. query })
end
for lhs, spec in pairs({
	["]f"] = { ts_move.goto_next_start, "@function.outer" },
	["[f"] = { ts_move.goto_previous_start, "@function.outer" },
	["]c"] = { ts_move.goto_next_start, "@class.outer" },
	["[c"] = { ts_move.goto_previous_start, "@class.outer" },
}) do
	local fn, query = spec[1], spec[2]
	vim.keymap.set({ "n", "x", "o" }, lhs, function() fn(query, "textobjects") end,
		{ desc = "Jump to " .. query })
end

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

-- Terminal buffers: relative line numbers only; no sign column or listchars.
local function term_ui()
	vim.opt_local.number = false
	vim.opt_local.relativenumber = true
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
-- Takes over the built-in `T` (till-backwards); `F`/`,`/`;` cover backwards search.
vim.keymap.set("n", "T", function() require("jj.annotate").line() end, { desc = "jj annotate line (tooltip)" })

-- servery
vim.keymap.set("n", "<space>s", servery_pick, { desc = "Switch nvim sessions" })
vim.keymap.set("n", "ZV", "<cmd>1Sv<cr>", { desc = "Go to previous session" })

-- snacks picker
vim.keymap.set("n", "<space>p", function() Snacks.picker.pickers() end, { desc = "Pickers" })
vim.keymap.set("n", "<space>t", function() Snacks.picker.lsp_workspace_symbols() end, { desc = "Workspace symbols" })
vim.keymap.set("n", "<space>B", function() Snacks.picker.buffers() end, { desc = "Buffers" })
vim.keymap.set("n", "<space>f", function() Snacks.picker.files() end, { desc = "Find files" })
vim.keymap.set("n", "<space>F", function() Snacks.picker.files({ hidden = true, ignored = true }) end,
	{ desc = "Find files (hidden + ignored)" })
vim.keymap.set("n", "?", function() Snacks.picker.grep() end, { desc = "Live grep" })
vim.keymap.set({ "n", "x" }, "<space>w", function() Snacks.picker.grep_word() end, { desc = "Grep word / selection" })
vim.keymap.set("n", "<space><space>", function() Snacks.picker.resume({ exclude = { "servery" } }) end, { desc = "Resume last picker" })
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
