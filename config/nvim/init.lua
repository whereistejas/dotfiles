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
-- vim.opt.cursorline = true
vim.opt.winborder = "single"
vim.opt.mouse = "n"

vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.wrap = true      -- Enable soft wrapping
vim.opt.linebreak = true -- Wrap at word boundaries

vim.opt.list = true
vim.opt.listchars = { tab = "→ ", trail = "·", nbsp = "␣", lead = "·" }

vim.opt.foldmethod = "expr"
vim.opt.foldlevelstart = 99
vim.opt.foldexpr = "v:lua.vim.treesitter.foldexpr()"

vim.wo.relativenumber = true
vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"

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
		if name == "telescope-fzf-native.nvim" and (kind == "install" or kind == "update") then
			local path = vim.fn.stdpath("data") .. "/site/pack/core/opt/telescope-fzf-native.nvim"
			vim.fn.system({ "make", "-C", path })
		end
		if name == "nvim-treesitter" and kind == "update" then
			if not ev.data.active then vim.cmd.packadd("nvim-treesitter") end
			vim.cmd("TSUpdate")
		end
	end,
})

vim.pack.add({
	-- Theme (loaded first so colorscheme is set before other plugins)
	"https://github.com/projekt0n/github-nvim-theme",
	"https://github.com/ellisonleao/gruvbox.nvim",
	"https://github.com/shortcuts/no-neck-pain.nvim",

	"https://github.com/wsdjeg/vim-fetch",
	"https://github.com/tpope/vim-surround",

	-- VCS
	"https://github.com/lewis6991/gitsigns.nvim",
	{ src = "https://github.com/nicolasgb/jj.nvim",             version = "v0.6.0" },
	"https://github.com/MunifTanjim/nui.nvim",

	-- Telescope
	"https://github.com/nvim-lua/plenary.nvim",
	"https://github.com/nvim-telescope/telescope-fzf-native.nvim",
	"https://github.com/nvim-telescope/telescope-file-browser.nvim",
	"https://github.com/nvim-telescope/telescope-live-grep-args.nvim",
	{ src = "https://github.com/nvim-telescope/telescope.nvim", version = "v0.2.1" },

	-- Completion
	"https://github.com/rafamadriz/friendly-snippets",
	{ src = "https://github.com/saghen/blink.cmp", version = vim.version.range("1.*") },

	-- Treesitter
	"https://github.com/nvim-treesitter/nvim-treesitter",

	-- LSP
	"https://github.com/folke/lazydev.nvim",
	"https://github.com/neovim/nvim-lspconfig",
})

-- Enable loader now that all plugins are in runtimepath
vim.loader.enable()

-- =============================================================================
-- Functions
-- =============================================================================

local builtin = require("telescope.builtin")

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

-- Telescope sorter that keeps fuzzy filtering but preserves finder order
-- (rg --sort path), so results stay grouped by folder while you type. Lower
-- score = higher in the list under sorting_strategy = "ascending", and
-- entry.index follows path order.
local function path_order_sorter()
	local sorters = require("telescope.sorters")
	local base = sorters.get_fzy_sorter()
	return sorters.Sorter:new({
		discard = true,
		scoring_function = function(_, prompt, line, entry)
			local score = base:scoring_function(prompt, line, entry)
			if score == nil or score == -1 then return -1 end
			return entry and entry.index or 1
		end,
		highlighter = function(_, prompt, display)
			return base:highlighter(prompt, display)
		end,
	})
end

-- Custom telescope pickers
local function find_files_all()
	builtin.find_files({
		find_command = { "rg", "--files", "--hidden", "--no-ignore", "--glob", "!.git/*", "--sort", "path" },
		sorting_strategy = "ascending",
		tiebreak = function(current_entry, existing_entry, _)
			return current_entry.index < existing_entry.index
		end,
	})
end

local function live_grep_args(opts)
	local prompt_parser = require("telescope-live-grep-args.prompt_parser")
	local sorters = require("telescope.sorters")
	local fzy = require("telescope.algos.fzy")
	opts = vim.tbl_extend("force", opts or {}, {
		sorter = sorters.Sorter:new({
			scoring_function = function() return 1 end,
			highlighter = function(_, prompt, display)
				local parts = prompt_parser.parse(prompt, true)
				local term = parts[1] or prompt
				return fzy.positions(term, display)
			end,
		}),
	})
	return require("telescope").extensions.live_grep_args.live_grep_args(opts)
end

local function file_browser_here()
	vim.cmd("Telescope file_browser path=%:p:h")
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
require("github-theme").setup({
	options = {
		transparent = false,
		styles = {
			comments = "italic",
			keywords = "bold",
		},
	},
})
vim.o.background = "light"
vim.cmd("colorscheme gruvbox")

-- gitsigns
require("gitsigns").setup()

-- jj.nvim
require("jj").setup({
	diff = {
		-- native = Neovim's built-in diff mode (nvim -d); no external diff plugin
		backend = "native",
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

-- Telescope
require("telescope").setup({
	defaults = {
		hidden = true,
		mappings = {
			i = {
				["<C-d>"] = function(bufnr) require("telescope.actions").preview_scrolling_down(bufnr) end,
				["<C-u>"] = function(bufnr) require("telescope.actions").preview_scrolling_up(bufnr) end,
			},
		},
		vimgrep_arguments = {
			"rg",
			"--color=never",
			"--no-heading",
			"--with-filename",
			"--line-number",
			"--column",
			"--smart-case",
			"--hidden",
		},
	},
	pickers = {
		find_files = {
			find_command = { "rg", "--files", "--hidden", "--glob", "!.git/*", "--sort", "path" },
			sorting_strategy = "ascending",
			sorter = path_order_sorter(),
			tiebreak = function(current_entry, existing_entry, _)
				return current_entry.index < existing_entry.index
			end,
		},
	},
})
require("telescope").load_extension("file_browser")
require("telescope").load_extension("live_grep_args")

-- no-neck-pain (centered layout)
require("no-neck-pain").setup({ width = 120 })

-- blink.cmp
require("blink.cmp").setup({
	keymap = { preset = "default" },
	appearance = { nerd_font_variant = "mono" },
	completion = {
		documentation = { auto_show = false },
	},
	sources = {
		default = { "lsp", "path", "snippets", "buffer" },
	},
	fuzzy = { implementation = "prefer_rust" },
})

-- Treesitter
require("nvim-treesitter").setup()
require("nvim-treesitter.install").install({ "typescript", "tsx", "lua", "rust", "ocaml", "json", "html", "css", "python",
	"ruby", "bash" })

-- lazydev (Lua LSP workspace libraries)
require("lazydev").setup({
	library = {
		{ path = "${3rd}/luv/library", words = { "vim%.uv" } },
		{ path = "blink.cmp" },
	},
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

local capabilities = require("blink.cmp").get_lsp_capabilities()

vim.lsp.config.lua_ls = {
	cmd = { "lua-language-server" },
	capabilities = capabilities,
	root_markers = { ".luarc.json", ".luarc.jsonc", ".luacheckrc", ".stylua.toml", "stylua.toml", "selene.toml", "selene.yml", ".git" },
}

vim.lsp.config.ts_ls = {
	cmd = { "typescript-language-server", "--stdio" },
	capabilities = capabilities,
	root_markers = { "tsconfig.json", "jsconfig.json", "package.json", ".git" },
}

vim.lsp.config.ocamllsp = {
	cmd = { "ocamllsp" },
	capabilities = capabilities,
	root_markers = { "dune-project", "dune-workspace", ".git", "*.opam" },
	filetypes = { "ocaml", "ocaml.menhir", "ocaml.interface", "ocaml.ocamllex", "reason", "dune" },
}

vim.lsp.config.eslint = {
	cmd = { "vscode-eslint-language-server", "--stdio" },
	capabilities = capabilities,
	root_markers = { ".eslintrc", ".eslintrc.js", ".eslintrc.json", ".eslintrc.yml", "eslint.config.js", "eslint.config.mjs", "eslint.config.ts" },
	settings = {
		validate = "on",
		run = "onType",
	},
}

vim.lsp.config.ruby_lsp = {
	cmd = { "ruby-lsp" },
	capabilities = capabilities,
	root_markers = { "Gemfile", ".git" },
	init_options = {
		formatter = "standard",
		linters = { "standard" },
	},
}

vim.lsp.config.ruff = {
	cmd = { "ruff", "server" },
	capabilities = capabilities,
	root_markers = { "pyproject.toml", "ruff.toml", ".ruff.toml", ".git" },
	filetypes = { "python" },
	init_options = {
		settings = {
			fixAll = false,
			organizeImports = false,
		},
	},
}

-- Host: bun-installed (needs `bun` to run, no system node). Container: the
-- Nix-wrapped binary on PATH bundles its own node.
local bun_bashls = vim.env.HOME .. "/.bun/bin/bash-language-server"
vim.lsp.config.bashls = {
	cmd = vim.uv.fs_stat(bun_bashls) and { "bun", bun_bashls, "start" }
		or { "bash-language-server", "start" },
	capabilities = capabilities,
	root_markers = { ".git" },
	filetypes = { "sh", "bash" },
}

vim.lsp.config.marksman = {
	cmd = { "marksman", "server" },
	capabilities = capabilities,
	root_markers = { ".marksman.toml", ".git" },
	filetypes = { "markdown", "markdown.mdx" },
}

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

vim.lsp.config.ty = {
	cmd = { "ty", "server" },
	capabilities = capabilities,
	root_markers = { "pyproject.toml", "ty.toml", ".git" },
	filetypes = { "python" },
	settings = {
		ty = {
			configuration = {
				environment = {
					["extra-paths"] = ty_extra_paths,
				},
			},
		},
	},
}

vim.lsp.enable("lua_ls")
vim.lsp.enable("rust_analyzer")
-- vim.lsp.enable("astro")
vim.lsp.enable("ts_ls")
vim.lsp.enable("eslint")
vim.lsp.enable("ocamllsp")
vim.lsp.enable("ruby_lsp")
vim.lsp.enable("ruff")
vim.lsp.enable("ty")
vim.lsp.enable("bashls")
vim.lsp.enable("marksman")

-- Diagnostics
vim.diagnostic.config({
	virtual_text = true,
	virtual_lines = true,
})

-- =============================================================================
-- Keymaps
-- =============================================================================

-- General
vim.keymap.set("n", "0", "^")
vim.keymap.set("n", "9", "$")
vim.keymap.set("n", "<left>", ":bp<CR>")
vim.keymap.set("n", "<right>", ":bn<CR>")
vim.keymap.set("n", "j", "gj")

-- Treesitter node selection (nvim 0.12.3+):
--   <up>/<down> expand to parent / shrink to child (normal + visual)
--   <left>/<right> select prev / next sibling (visual only)
vim.keymap.set({ "n", "x" }, "<up>", function() vim.treesitter.select("parent", vim.v.count1) end)
vim.keymap.set({ "n", "x" }, "<down>", function() vim.treesitter.select("child", vim.v.count1) end)
vim.keymap.set("x", "<left>", function() vim.treesitter.select("prev", vim.v.count1) end)
vim.keymap.set("x", "<right>", function() vim.treesitter.select("next", vim.v.count1) end)

-- Copy selection + context (path:line-range (Symbol.path)) to the clipboard
vim.keymap.set("x", "Y", copy_selection_with_context,
	{ desc = "Copy selection with path/range/symbol context" })

-- Window navigation — move between splits in every mode (insert/visual/terminal too).
-- <Cmd> runs wincmd without leaving the current mode.
for key, desc in pairs({
	h = "Move to left split",
	j = "Move to split below",
	k = "Move to split above",
	l = "Move to right split",
}) do
	vim.keymap.set({ "n", "i", "v", "t" }, "<D-" .. key .. ">", "<Cmd>wincmd " .. key .. "<CR>", { desc = desc })
end

-- Double-<Tab> cycles to the next window/split.
vim.keymap.set("n", "<Tab><Tab>", "<C-w>w", { desc = "Cycle to next window" })

-- Tabs — switch to tab N in every mode (insert/visual/terminal too).
-- <Cmd> runs the command without leaving the current mode.
for i = 1, 4 do
	vim.keymap.set({ "n", "i", "v", "t" }, "<D-" .. i .. ">", "<Cmd>tabnext " .. i .. "<CR>", { desc = "Go to tab " .. i })
end

-- Terminal — double <Esc> leaves terminal mode (single <Esc> still reaches the program).
vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-n>", { desc = "Exit terminal mode" })

-- Git (gitsigns)
vim.keymap.set("n", "]h", function() require("gitsigns").nav_hunk("next") end)
vim.keymap.set("n", "[h", function() require("gitsigns").nav_hunk("prev") end)

-- jj.nvim
vim.keymap.set("n", "<leader>jj", "<cmd>J log<CR>", { desc = "jj log (jj.nvim)" })
vim.keymap.set("n", "<leader>js", "<cmd>J status<CR>", { desc = "jj status (jj.nvim)" })

-- Telescope
vim.keymap.set("n", "<space>t", builtin.builtin)
vim.keymap.set("n", "<space>b", builtin.buffers)
vim.keymap.set("n", "<space>f", builtin.find_files)
vim.keymap.set("n", "<space>fa", find_files_all)
vim.keymap.set("n", "?", live_grep_args)
vim.keymap.set("n", "<space><space>", builtin.resume)
vim.keymap.set("n", "<space>r", builtin.lsp_references)
vim.keymap.set("n", "<space>i", builtin.lsp_implementations)
vim.keymap.set("n", "<space>d", builtin.lsp_definitions)
vim.keymap.set("n", "<space>o", builtin.lsp_document_symbols)
vim.keymap.set("n", "<space>O", function()
	vim.lsp.buf.document_symbol({
		on_list = function(opts)
			vim.fn.setloclist(0, {}, " ", opts)
			vim.cmd("vert leftabove lopen 40")
		end,
	})
end, { desc = "Document symbols (left split)" })
vim.keymap.set("n", "<space>m", builtin.diagnostics)
vim.keymap.set("n", "M", vim.diagnostic.open_float)
vim.keymap.set("n", "<space>k", builtin.keymaps)
vim.keymap.set("n", "<space>c", file_browser_here)

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

		if client and client.name == "eslint" then
			vim.api.nvim_create_autocmd("BufWritePre", {
				buffer = args.buf,
				callback = function()
					local bufnr = vim.api.nvim_get_current_buf()
					client:request_sync("workspace/executeCommand", {
						command = "eslint.applyAllFixes",
						arguments = { {
							uri = vim.uri_from_bufnr(bufnr),
							version = vim.lsp.util.buf_versions[bufnr],
						} },
					}, 3000)
				end,
			})
			-- Only format if the server supports it, and skip LSPs where another tool owns formatting (eslint for TS, ruff/ty for Python)
		elseif client and client.server_capabilities.documentFormattingProvider
			and client.name ~= "ts_ls" and client.name ~= "ruff" and client.name ~= "ty" then
			vim.api.nvim_create_autocmd("BufWritePre", {
				buffer = args.buf,
				callback = function()
					vim.lsp.buf.format({
						async = false,
						id = args.data.client_id,
					})
				end,
			})
		end
	end,
})
