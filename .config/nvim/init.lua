-- =============================================================================
-- Options
-- =============================================================================

vim.opt.clipboard = "unnamedplus"
vim.opt.signcolumn = "yes"
vim.opt.cursorline = true
vim.opt.mouse = "n"
vim.wo.relativenumber = true

vim.opt.tabstop = 4
vim.opt.shiftwidth = 4

local lsp_indent = {
	ts_ls = { tabstop = 2, shiftwidth = 2, expandtab = true },
	rust_analyzer = { tabstop = 4, shiftwidth = 4, expandtab = true },
	astro = { tabstop = 2, shiftwidth = 2, expandtab = true },
	ocamllsp = { tabstop = 2, shiftwidth = 2, expandtab = true },
}

vim.opt.list = true
vim.opt.listchars = { tab = "→ ", trail = "·", nbsp = "␣", lead = "·" }

vim.opt.foldmethod = "expr"
vim.opt.foldlevelstart = 99
vim.opt.foldexpr = "v:lua.vim.treesitter.foldexpr()"

-- =============================================================================
-- Keymaps
-- =============================================================================

vim.keymap.set("n", "0", "^")
vim.keymap.set("n", "9", "$")
vim.keymap.set("n", "<up>", "<nop>")
vim.keymap.set("n", "<down>", "<nop>")
vim.keymap.set("n", "<left>", ":bp<CR>")
vim.keymap.set("n", "<right>", ":bn<CR>")
vim.keymap.set("n", "<C-s>", "<cmd>wa<CR>", { silent = true })
vim.keymap.set("n", "<D-s>", "<cmd>wa<CR>", { silent = true })

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

	-- AI completion
	"https://github.com/Exafunction/windsurf.nvim",

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
vim.cmd("colorscheme gruvbox")

-- gitsigns
require("gitsigns").setup()

-- jj.nvim
require("jj").setup({})

-- Telescope
require("telescope").setup({
	defaults = {
		hidden = true,
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

-- Windsurf / Codeium
require("codeium").setup({
	enable_cmp_source = false,
})

-- blink.cmp
require("blink.cmp").setup({
	keymap = { preset = "default" },
	appearance = { nerd_font_variant = "mono" },
	completion = { documentation = { auto_show = false } },
	sources = {
		default = { "lsp", "path", "snippets", "buffer", "codeium" },
		providers = {
			codeium = {
				name = "Codeium",
				module = "codeium.blink",
				async = true,
			},
		},
	},
	fuzzy = { implementation = "prefer_rust" },
})

-- Treesitter
require("nvim-treesitter").setup()
require("nvim-treesitter.install").install({ "typescript", "tsx", "lua", "rust", "ocaml", "json", "html", "css", "python",
	"ruby" })

-- lazydev (Lua LSP workspace libraries)
require("lazydev").setup({
	library = {
		{ path = "${3rd}/luv/library", words = { "vim%.uv" } },
		{ path = "blink.cmp" },
	},
})

-- LSP
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
		if client and lsp_indent[client.name] then
			for opt, val in pairs(lsp_indent[client.name]) do
				vim.bo[args.buf][opt] = val
			end
		end

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
