-- =============================================================================
-- Options
-- =============================================================================

vim.opt.clipboard = "unnamedplus"
vim.opt.signcolumn = "yes"
-- vim.opt.cursorline = true
vim.opt.winborder = "single"
vim.opt.mouse = "n"
vim.wo.relativenumber = true

vim.opt.tabstop = 4
vim.opt.shiftwidth = 4
vim.opt.wrap = true      -- Enable soft wrapping
vim.opt.linebreak = true -- Wrap at word boundaries

vim.opt.list = true
vim.opt.listchars = { tab = "→ ", trail = "·", nbsp = "␣", lead = "·" }

vim.opt.foldmethod = "expr"
vim.opt.foldlevelstart = 99
vim.opt.foldexpr = "v:lua.vim.treesitter.foldexpr()"
vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"

-- =============================================================================
-- Keymaps
-- =============================================================================

vim.keymap.set("n", "0", "^")
vim.keymap.set("n", "9", "$")
vim.keymap.set("n", "<up>", "<nop>")
vim.keymap.set("n", "<down>", "<nop>")
vim.keymap.set("n", "<left>", ":bp<CR>")
vim.keymap.set("n", "<right>", ":bn<CR>")
vim.keymap.set("n", "j", "gj")

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
	"https://github.com/junegunn/goyo.vim",

	"https://github.com/wsdjeg/vim-fetch",
	"https://github.com/tpope/vim-surround",

	-- VCS
	"https://github.com/lewis6991/gitsigns.nvim",
	{ src = "https://github.com/nicolasgb/jj.nvim",             version = "v0.5.0" },
	"https://github.com/MunifTanjim/nui.nvim",
	"https://github.com/julienvincent/hunk.nvim",

	-- Telescope
	"https://github.com/nvim-lua/plenary.nvim",
	"https://github.com/nvim-telescope/telescope-fzf-native.nvim",
	"https://github.com/nvim-telescope/telescope-file-browser.nvim",
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
-- Plugin configuration
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
vim.o.background = "light"
vim.cmd("colorscheme gruvbox")

-- gitsigns
require("gitsigns").setup()
vim.keymap.set("n", "]h", function() require("gitsigns").nav_hunk("next") end)
vim.keymap.set("n", "[h", function() require("gitsigns").nav_hunk("prev") end)

-- jj.nvim
require("jj").setup()

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
			tiebreak = function(current_entry, existing_entry, _)
				return current_entry.index < existing_entry.index
			end,
		},
	},
})
require("telescope").load_extension("file_browser")

local builtin = require("telescope.builtin")
vim.keymap.set("n", "<space>t", builtin.builtin)
vim.keymap.set("n", "<space>b", builtin.buffers)
vim.keymap.set("n", "<space>f", builtin.find_files)
vim.keymap.set("n", "<space>fa", function()
	builtin.find_files({
		find_command = { "rg", "--files", "--hidden", "--no-ignore", "--glob", "!.git/*", "--sort", "path" },
		sorting_strategy = "ascending",
		tiebreak = function(current_entry, existing_entry, _)
			return current_entry.index < existing_entry.index
		end,
	})
end)
vim.keymap.set("n", "?", builtin.live_grep)
vim.keymap.set("n", "<space><space>", builtin.resume)
vim.keymap.set("n", "<space>r", builtin.lsp_references)
vim.keymap.set("n", "<space>i", builtin.lsp_implementations)
vim.keymap.set("n", "<space>d", builtin.lsp_definitions)
vim.keymap.set("n", "<space>o", builtin.lsp_document_symbols)
vim.keymap.set("n", "<space>m", builtin.diagnostics)
vim.keymap.set("n", "M", vim.diagnostic.open_float)
vim.keymap.set("n", "<space>k", builtin.keymaps)
vim.keymap.set("n", "<space>c", ":Telescope file_browser path=%:p:h<CR>")
vim.api.nvim_set_hl(0, "JJChangeId", { bold = true })

local JJ_ID_WIDTH = 12
local JJ_AGE_WIDTH = 15
local jj_log_tpl = 'change_id.shortest() ++ "\t" ++ change_id.short(12) ++ "\t" ++ committer.timestamp().ago() ++ "\t" ++ coalesce(description.first_line(), "(no description)") ++ "\n"'

local function jj_cd_to_repo()
	local repo = find_jj_repo()
	if repo then vim.cmd.cd(repo) end
	return vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
end

local function jj_log_entries(extra_args)
	local cmd = "jj log -r '::@' --no-graph -T " .. vim.fn.shellescape(jj_log_tpl)
	if extra_args then cmd = cmd .. " " .. extra_args end
	local lines = vim.fn.systemlist(cmd)
	if vim.v.shell_error ~= 0 then return nil end
	local entries = {}
	for _, line in ipairs(lines) do
		local short, full, age, desc = line:match("^(%S+)\t(%S+)\t(.-)\t(.*)$")
		if short then
			table.insert(entries, { id_short = short, id_full = full, age = age, desc = desc })
		end
	end
	return #entries > 0 and entries or nil
end

local function jj_log_entry_maker(e)
	local age_pad = e.age .. string.rep(" ", math.max(0, JJ_AGE_WIDTH - #e.age))
	local line = e.id_full .. "  " .. age_pad .. "  " .. e.desc
	local short_len = #e.id_short
	local age_start = JJ_ID_WIDTH + 2
	return {
		value = e,
		display = function()
			return line, {
				{ { 0, short_len }, "JJChangeId" },
				{ { short_len, JJ_ID_WIDTH }, "Comment" },
				{ { age_start, age_start + JJ_AGE_WIDTH }, "Comment" },
			}
		end,
		ordinal = e.id_short .. " " .. e.desc,
	}
end

local function jj_diff_previewer(title, cmd_fn)
	return require("telescope.previewers").new_buffer_previewer({
		title = title,
		define_preview = function(self, entry)
			local out = vim.fn.systemlist(cmd_fn(entry))
			vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, out)
			vim.bo[self.state.bufnr].filetype = "diff"
		end,
	})
end

-- jj status: changed files in current commit
vim.keymap.set("n", "<space>j", function()
	local repo_name = jj_cd_to_repo()
	local lines = vim.fn.systemlist("jj diff --summary")
	if vim.v.shell_error ~= 0 or #lines == 0 then
		vim.notify("No changes in current jj commit", vim.log.levels.INFO)
		return
	end
	local files = {}
	for _, line in ipairs(lines) do
		local name = line:match("^[MADRC]%s+(.+)$")
		if name then table.insert(files, name) end
	end
	require("telescope.pickers").new({}, {
		prompt_title = "jj status: " .. repo_name,
		finder = require("telescope.finders").new_table({ results = files }),
		sorter = require("telescope.config").values.generic_sorter({}),
		previewer = jj_diff_previewer("jj diff", function(entry)
			return "jj diff --git " .. vim.fn.shellescape(entry.value)
		end),
	}):find()
end)

-- jj log: commits on the current change
vim.keymap.set("n", "<space>jl", function()
	local repo_name = jj_cd_to_repo()
	local entries = jj_log_entries()
	if not entries then
		vim.notify("No jj log entries", vim.log.levels.INFO)
		return
	end
	require("telescope.pickers").new({}, {
		prompt_title = "jj log: " .. repo_name,
		finder = require("telescope.finders").new_table({ results = entries, entry_maker = jj_log_entry_maker }),
		sorter = require("telescope.config").values.generic_sorter({}),
		previewer = jj_diff_previewer("jj show", function(entry)
			return "jj show --no-pager --git " .. vim.fn.shellescape(entry.value.id_short)
		end),
	}):find()
end)

-- jj file log: commits that changed the current file
vim.keymap.set("n", "<space>jf", function()
	jj_cd_to_repo()
	local bufpath = vim.api.nvim_buf_get_name(0)
	if bufpath == "" then
		vim.notify("No file in current buffer", vim.log.levels.WARN)
		return
	end
	local rel = vim.fn.fnamemodify(bufpath, ":.")
	local entries = jj_log_entries(vim.fn.shellescape(rel))
	if not entries then
		vim.notify("No commits touching " .. rel, vim.log.levels.INFO)
		return
	end
	local filename = vim.fn.fnamemodify(rel, ":t")
	require("telescope.pickers").new({}, {
		prompt_title = "jj log: " .. filename,
		finder = require("telescope.finders").new_table({ results = entries, entry_maker = jj_log_entry_maker }),
		sorter = require("telescope.config").values.generic_sorter({}),
		previewer = jj_diff_previewer("jj diff: " .. filename, function(entry)
			return "jj diff -r " .. vim.fn.shellescape(entry.value.id_short) .. " --git " .. vim.fn.shellescape(rel)
		end),
	}):find()
end)

-- blink.cmp
require("blink.cmp").setup({
	keymap = { preset = "default" },
	appearance = { nerd_font_variant = "mono" },
	completion = { documentation = { auto_show = false } },
	sources = {
		default = { "lsp", "path", "snippets", "buffer" },
	},
	fuzzy = { implementation = "prefer_rust" },
})

-- Treesitter
require("nvim-treesitter").setup()
require("nvim-treesitter.install").install({ "typescript", "tsx", "lua", "rust", "ocaml", "json", "html", "css", "python",
	"ruby", "bash" })
vim.keymap.set("n", "gn", function() require("nvim-treesitter.incremental_selection").init_selection() end)
vim.keymap.set("v", "gn", function() require("nvim-treesitter.incremental_selection").node_incremental() end)
vim.keymap.set("v", "gi", function() require("nvim-treesitter.incremental_selection").node_decremental() end)

-- lazydev (Lua LSP workspace libraries)
require("lazydev").setup({
	library = {
		{ path = "${3rd}/luv/library", words = { "vim%.uv" } },
		{ path = "blink.cmp" },
	},
})

-- LSP
-- Reformat long param/field lists in hover: put each element on its own line.
-- In 0.12, vim.lsp.buf.hover() calls open_floating_preview directly (not via
-- handlers), so this monkey-patch is the correct interception point.
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

vim.lsp.config.bashls = {
	cmd = { "bash-language-server", "start" },
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

vim.lsp.config.ty = {
	cmd = { "ty", "server" },
	capabilities = capabilities,
	root_markers = { "pyproject.toml", "ty.toml", ".git" },
	filetypes = { "python" },
	settings = {
		ty = {
			configuration = {
				environment = {
					["extra-paths"] = { "~/build/wst_core/python", "~/build/deps/tornado-openapi3/" },
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

-- =============================================================================
-- Diagnostics & LSP autocommands
-- =============================================================================

vim.diagnostic.config({
	virtual_text = true,
	virtual_lines = true,
})

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
		elseif client and client.name ~= "ts_ls" and client.name ~= "ruff" and client.name ~= "ty" then
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
