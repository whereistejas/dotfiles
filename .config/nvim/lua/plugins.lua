return {
	"wsdjeg/vim-fetch",
	"tpope/vim-surround",
	"lewis6991/gitsigns.nvim",
	{
		'nvim-telescope/telescope.nvim',
		tag = '0.1.8',
		dependencies = {
			'nvim-lua/plenary.nvim',
			{
				'nvim-telescope/telescope-fzf-native.nvim', build = 'make'
			}
		},
		config = function()
			vim.keymap.set("n", "<space>t", require("telescope.builtin").builtin)
			vim.keymap.set("n", "<space>b", require("telescope.builtin").buffers)
			vim.keymap.set("n", "<space>f", require("telescope.builtin").find_files)
			vim.keymap.set("n", "?", require("telescope.builtin").live_grep)
			vim.keymap.set("n", "<space>l", require("telescope.builtin").resume)
			vim.keymap.set("n", "<space>r", require("telescope.builtin").lsp_references)
			vim.keymap.set("n", "<space>i", require("telescope.builtin").lsp_implementations)
			vim.keymap.set("n", "<space>d", require("telescope.builtin").lsp_definitions)
			vim.keymap.set("n", "<space>d", require("telescope.builtin").diagnostics)
		end
	},
	{
		"nvim-telescope/telescope-file-browser.nvim",
		dependencies = { "nvim-telescope/telescope.nvim", "nvim-lua/plenary.nvim" },
	},
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
	{
		'saghen/blink.cmp',
		-- optional: provides snippets for the snippet source
		dependencies = { 'rafamadriz/friendly-snippets' },

		-- use a release tag to download pre-built binaries
		version = '1.*',
		-- AND/OR build from source, requires nightly: https://rust-lang.github.io/rustup/concepts/channels.html#working-with-nightly-rust
		-- build = 'cargo build --release',
		-- If you use nix, you can build from source using latest nightly rust with:
		-- build = 'nix run .#build-plugin',

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
				default = { 'lsp', 'path', 'snippets', 'buffer' },
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
	{ "nvim-treesitter/nvim-treesitter", build = ":TSUpdate" },
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

			vim.lsp.config.rust_analyzer = {
				cmd = { 'rust-analyzer' },
				settings = {
					['rust-analyzer'] = {
						runnables = {
							extraEnv = {
								CARGO_INCREMENTAL = "0",
								RUST_BACKTRACE = "full",
								RUSTFLAGS = "--cfg=web_sys_unstable_apis --cfg=tokio_unstable -Zincremental-verify-ich"
							}
						}
					}
				}
			}

			vim.lsp.config.astro = {
				cmd = { 'astro-ls', '--stdio' },
			}

			-- Enable the LSP servers
			vim.lsp.enable('lua_ls')
			vim.lsp.enable('rust_analyzer')
			vim.lsp.enable('astro')
		end,
	}
}
