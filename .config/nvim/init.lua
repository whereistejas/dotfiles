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
		"lewis6991/gitsigns.nvim",

		{
			"nicolasgb/jj.nvim",
			version = "*", -- Use latest stable release
			-- Or from the main branch (uncomment the branch line and comment the version line)
			-- branch = "main",
			config = function()
				require("jj").setup({})
			end,
		},

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
				vim.keymap.set("n", "<space>fa", function()
					builtin.find_files({
						find_command = { "rg", "--files", "--hidden", "--no-ignore", "--glob", "!.git/*" },
					})
				end)
				vim.keymap.set("n", "?", builtin.live_grep)
				vim.keymap.set("n", "<space><space>", builtin.resume)
				vim.keymap.set("n", "<space>r", builtin.lsp_references)
				vim.keymap.set("n", "<space>i", builtin.lsp_implementations)
				vim.keymap.set("n", "<space>d", builtin.lsp_definitions)
				vim.keymap.set("n", "<space>m", builtin.diagnostics)
				vim.keymap.set("n", "<space>k", builtin.keymaps)
				vim.keymap.set("n", "<space>c", ":Telescope file_browser path=%:p:h<CR>")
			end
		},

		-- Theme
		{
			"projekt0n/github-nvim-theme",
			lazy = false,
			priority = 1000,
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
				vim.cmd("colorscheme github_light")
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

			opts = {
				keymap = { preset = 'default' },

				appearance = {
					nerd_font_variant = 'mono'
				},

				-- (Default) Only show the documentation popup when manually triggered
				completion = { documentation = { auto_show = false } },

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
				require("nvim-treesitter.configs").setup({
					ensure_installed = { "typescript", "tsx", "lua", "rust", "ocaml", "json", "html", "css" },
					highlight = { enable = true },
				})
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
							{ path = "blink.cmp" },
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

				vim.lsp.config.ocamllsp = {
					cmd = { 'ocamllsp' },
					capabilities = capabilities,
					root_markers = { 'dune-project', 'dune-workspace', '.git', '*.opam' },
					filetypes = { 'ocaml', 'ocaml.menhir', 'ocaml.interface', 'ocaml.ocamllex', 'reason', 'dune' },
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
				-- vim.lsp.enable('astro')
				vim.lsp.enable('ts_ls')
				vim.lsp.enable('eslint')
				vim.lsp.enable('ocamllsp')
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
						arguments = { {
							uri = vim.uri_from_bufnr(bufnr),
							version = vim.lsp.util.buf_versions[bufnr],
						} },
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
