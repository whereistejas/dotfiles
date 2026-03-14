-- =============================================================================
-- Leaders
-- =============================================================================

vim.g.mapleader = " "
vim.g.maplocalleader = "\\"

-- =============================================================================
-- Options
-- =============================================================================

vim.opt.clipboard = "unnamedplus"
vim.opt.signcolumn = "yes"
vim.opt.cursorline = true
vim.opt.mouse = "n"
vim.opt.completeopt:append("noselect")
vim.wo.relativenumber = true

vim.opt.tabstop = 4
vim.opt.shiftwidth = 4

local lsp_indent = {
	lua_ls = { tabstop = 4, shiftwidth = 4, expandtab = false },
	ts_ls = { tabstop = 2, shiftwidth = 2, expandtab = true },
	rust_analyzer = { tabstop = 4, shiftwidth = 4, expandtab = true },
	astro = { tabstop = 2, shiftwidth = 2, expandtab = true },
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
-- Bootstrap lazy.nvim
-- =============================================================================

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
	local lazyrepo = "https://github.com/folke/lazy.nvim.git"
	local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
	if vim.v.shell_error ~= 0 then
		vim.api.nvim_echo({
			{ "Failed to clone lazy.nvim:\n", "ErrorMsg" },
			{ out,                            "WarningMsg" },
			{ "\nPress any key to exit..." },
		}, true, {})
		vim.fn.getchar()
		os.exit(1)
	end
end
vim.opt.rtp:prepend(lazypath)

-- =============================================================================
-- Plugins
-- =============================================================================

require("lazy").setup({
	spec = {
		"wsdjeg/vim-fetch",
		"tpope/vim-surround",
		"tpope/vim-fugitive",
		"lewis6991/gitsigns.nvim",

		-- Telescope
		{
			'nvim-telescope/telescope.nvim',
			version = '*',
			dependencies = {
				'nvim-lua/plenary.nvim',
				{ 'nvim-telescope/telescope-fzf-native.nvim', build = 'make' },
				{
					"nvim-telescope/telescope-file-browser.nvim",
					dependencies = { "nvim-lua/plenary.nvim" },
				},
			},
			config = function()
				require("telescope").setup {
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
							find_command = { "rg", "--files", "--hidden", "--glob", "!.git/*" },
						},
					},
				}
				require("telescope").load_extension "file_browser"

				local builtin = require("telescope.builtin")
				vim.keymap.set("n", "<space>t", builtin.builtin)
				vim.keymap.set("n", "<space>b", builtin.buffers)
				vim.keymap.set("n", "<space>f", builtin.find_files)
				vim.keymap.set("n", "?", builtin.live_grep)
				vim.keymap.set("n", "<space><space>", builtin.resume)
				vim.keymap.set("n", "<space>r", builtin.lsp_references)
				vim.keymap.set("n", "<space>i", builtin.lsp_implementations)
				vim.keymap.set("n", "<space>d", builtin.lsp_definitions)
				vim.keymap.set("n", "<space>d", builtin.diagnostics)
				vim.keymap.set("n", "<space>c", ":Telescope file_browser path=%:p:h<CR>")
			end
		},

		-- Theme
		{
			"projekt0n/github-nvim-theme",
			lazy = false, -- or true if you want it to load on a specific event
			priority = 1000, -- load before other plugins so the theme is applied early
			config = function()
				require("github-theme").setup({
					options = {
						transparent = false,
						styles = {
							comments = "italic",
							keywords = "bold",
						},
					}
				})
				vim.cmd("colorscheme github_light") -- or github_light, github_dimmed
			end,
		},

		-- AI Completion
		{
			"Exafunction/windsurf.nvim",
			dependencies = { "nvim-lua/plenary.nvim" },
			config = function()
				require("codeium").setup({
				enable_cmp_source = false,
			})
			end,
		},

		-- Completion
		{
			'saghen/blink.cmp',
			-- optional: provides snippets for the snippet source
			dependencies = {
				'rafamadriz/friendly-snippets',
				'Exafunction/windsurf.nvim',
			},

			version = '1.*',

			---@module 'blink.cmp'
			---@type blink.cmp.Config
			opts = {
				-- 'default' (recommended) for mappings similar to built-in completions (C-y to accept)
				-- 'super-tab' for mappings similar to vscode (tab to accept)
				-- 'enter' for enter to accept
				-- 'none' for no mappings
				--
				-- All presets have the following mappings:
				-- C-space: Open menu or open docs if already open
				-- C-n/C-p or Up/Down: Select next/previous item
				-- C-e: Hide menu
				-- C-k: Toggle signature help (if signature.enabled = true)
				--
				-- See :h blink-cmp-config-keymap for defining your own keymap
				keymap = { preset = 'default' },

				appearance = {
					-- 'mono' (default) for 'Nerd Font Mono' or 'normal' for 'Nerd Font'
					-- Adjusts spacing to ensure icons are aligned
					nerd_font_variant = 'mono'
				},

				-- (Default) Only show the documentation popup when manually triggered
				completion = { documentation = { auto_show = false } },

				-- Default list of enabled providers defined so that you can extend it
				-- elsewhere in your config, without redefining it, due to `opts_extend`
				sources = {
					default = { 'lsp', 'path', 'snippets', 'buffer', 'codeium' },
					providers = {
						codeium = {
							name = 'Codeium',
							module = 'codeium.blink',
							async = true,
						},
					},
				},

				-- (Default) Rust fuzzy matcher for typo resistance and significantly better performance
				-- You may use a lua implementation instead by using `implementation = "lua"` or fallback to the lua implementation,
				-- when the Rust fuzzy matcher is not available, by using `implementation = "prefer_rust"`
				--
				-- See the fuzzy documentation for more information
				fuzzy = { implementation = "prefer_rust" }
			},
			opts_extend = { "sources.default" }
		},

		-- Treesitter
		{
			"nvim-treesitter/nvim-treesitter",
			lazy = false,
			build = ":TSUpdate",
			config = function()
				require("nvim-treesitter").install({ "typescript", "tsx", "lua", "rust", "astro", "json", "html", "css" })
			end,
		},

		-- LSP
		{
			"neovim/nvim-lspconfig",
			dependencies = {
				{
					"folke/lazydev.nvim",
					ft = "lua", -- only load on lua files
					opts = {
						library = {
							-- See the configuration section for more details
							-- Load luvit types when the `vim.uv` word is found
							{ path = "${3rd}/luv/library", words = { "vim%.uv" } },
						},
					},
				},
			},
			config = function()
				local capabilities = require("blink.cmp").get_lsp_capabilities()

				-- Using the new vim.lsp.config API for Neovim 0.11+
				vim.lsp.config.lua_ls = {
					cmd = { 'lua-language-server' },
					capabilities = capabilities,
					root_markers = { '.luarc.json', '.luarc.jsonc', '.luacheckrc', '.stylua.toml', 'stylua.toml', 'selene.toml', 'selene.yml', '.git' },
				}

				vim.lsp.config.ts_ls = {
					cmd = { 'typescript-language-server', '--stdio' },
					capabilities = capabilities,
					root_markers = { 'tsconfig.json', 'jsconfig.json', 'package.json', '.git' },
				}

				vim.lsp.config.eslint = {
					cmd = { 'vscode-eslint-language-server', '--stdio' },
					capabilities = capabilities,
					root_markers = { '.eslintrc', '.eslintrc.js', '.eslintrc.json', '.eslintrc.yml', 'eslint.config.js', 'eslint.config.mjs', 'eslint.config.ts' },
					settings = {
						validate = 'on',
						run = 'onType',
					},
				}

				-- Enable the LSP servers
				vim.lsp.enable('lua_ls')
				vim.lsp.enable('rust_analyzer')
				vim.lsp.enable('astro')
				vim.lsp.enable('ts_ls')
				vim.lsp.enable('eslint')
			end,
		}
	},
	install = { colorscheme = { "default" } },
	checker = { enabled = true },
})

-- =============================================================================
-- Diagnostics & LSP autocommands
-- =============================================================================

vim.diagnostic.config {
	virtual_text = true,
	virtual_lines = true
}

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
						arguments = {{
							uri = vim.uri_from_bufnr(bufnr),
							version = vim.lsp.util.buf_versions[bufnr],
						}},
					}, 3000)
				end,
			})
		elseif client and client.name ~= "ts_ls" then
			vim.api.nvim_create_autocmd("BufWritePre", {
				buffer = args.buf,
				callback = function()
					vim.lsp.buf.format {
						async = false,
						id = args.data.client_id,
					}
				end,
			})
		end
	end
})
