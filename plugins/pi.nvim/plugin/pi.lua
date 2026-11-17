if vim.g.loaded_pi then return end
vim.g.loaded_pi = true

vim.api.nvim_create_autocmd("SessionLoadPost", {
	group = vim.api.nvim_create_augroup("pi.resume", { clear = true }),
	desc = "Start the pi terminals a session restored hidden",
	callback = function() require("pi").resume_hidden() end,
})

vim.api.nvim_create_autocmd("TermOpen", {
	group = vim.api.nvim_create_augroup("pi.definition", { clear = true }),
	desc = "gd in pi terminals jumps to the LSP symbol under the cursor",
	callback = function(ev)
		if not require("pi").cwd(ev.buf) then return end
		vim.keymap.set("n", "gd", function() require("pi.definition").jump() end, {
			buffer = ev.buf,
			desc = "Go to the definition of the symbol under the cursor",
		})
	end,
})

vim.api.nvim_create_user_command("Pi", function(opts)
	require("pi").command(opts.args)
end, {
	nargs = "*",
	desc = "Run a pi slash command (`:Pi tree` runs /tree) in a pi terminal and focus it",
})
