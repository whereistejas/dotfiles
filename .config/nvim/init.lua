vim.opt.signcolumn = "yes"
vim.opt.cursorline = true
vim.wo.relativenumber = true

vim.opt.tabstop = 4
vim.opt.shiftwidth = 4

vim.opt.foldmethod = "expr"
vim.opt.foldlevelstart = 99
vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"

vim.opt.mouse = "n"

-- Keymaps
vim.g.mapleader = "<Space>"

vim.keymap.set("n", "0", "^")
vim.keymap.set("n", "9", "$")
vim.keymap.set("n", "<up>", "<nop>")
vim.keymap.set("n", "<down>", "<nop>")
vim.keymap.set("n", "<left>", "<nop>")
vim.keymap.set("n", "<right>", "<nop>")
vim.keymap.set("n", "<up>", "<nop>")
vim.keymap.set("n", "<down>", "<nop>")
vim.keymap.set("n", "<left>", "<nop>")
vim.keymap.set("n", "<right>", "<nop>")
vim.keymap.set("n", "<left>", ":bp<CR>")
vim.keymap.set("n", "<right>", ":bn<CR>")

-- Plugins and stuff
require("config.lazy")

vim.diagnostic.config {
	virtual_text = true,
	virtual_lines = true
}

vim.api.nvim_create_autocmd("LspAttach", {
	group = vim.api.nvim_create_augroup("lsp", { clear = true }),
	callback = function(args)
		vim.api.nvim_create_autocmd("BufWritePre", {
			buffer = args.buf,
			callback = function()
				vim.lsp.buf.format { async = false, id = args.data.client_id }
			end,
		})
	end
})

vim.cmd("set completeopt+=noselect")

require("telescope").setup {
	defaults = {
		file_ignore_patterns = {
			"borsh_schema/",
			"vendor/",
			"target/",
			"node_modules",
			".git/",
			".jj/"
		}
	}
}
require("telescope").load_extension "file_browser"
vim.keymap.set("n", "<space>fb", ":Telescope file_browser path=%:p:h<CR>")
