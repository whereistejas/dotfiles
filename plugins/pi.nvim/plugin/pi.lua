if vim.g.loaded_pi then return end
vim.g.loaded_pi = true

vim.api.nvim_create_user_command("Pi", function(opts)
	require("pi").command(opts.args)
end, {
	nargs = "*",
	desc = "Run a pi slash command (`:Pi tree` runs /tree) in a pi terminal and focus it",
})
