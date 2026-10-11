if vim.g.loaded_jumanji then return end
vim.g.loaded_jumanji = true

local function set_highlights()
	for name, link in pairs({
		JumanjiGraph = "Comment",
		JumanjiWorkingCopy = "Title",
		JumanjiChangeIdPrefix = "Special",
		JumanjiChangeId = "Comment",
		JumanjiCommitId = "Comment",
		JumanjiBookmark = "Constant",
		JumanjiConflict = "DiagnosticError",
		JumanjiDim = "Comment",
		JumanjiAuthor = "Identifier",
		JumanjiTimestamp = "Comment",
	}) do
		vim.api.nvim_set_hl(0, name, { link = link, default = true })
	end
end

set_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("jumanji-highlights", { clear = true }),
	callback = set_highlights,
})

vim.api.nvim_create_user_command("Jumanji", function(opts)
	require("jumanji").open(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", desc = "jj commit log, optionally filtered by a revset" })
