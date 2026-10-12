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
		JumanjiFileAdded = "Added",
		JumanjiFileModified = "Changed",
		JumanjiFileDeleted = "Removed",
		JumanjiSelected = "Special",
	}) do
		vim.api.nvim_set_hl(0, name, { link = link, default = true })
	end
end

set_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("jumanji-highlights", { clear = true }),
	callback = set_highlights,
})

local read_group = vim.api.nvim_create_augroup("jumanji-read", { clear = true })
vim.api.nvim_create_autocmd("BufReadCmd", {
	group = read_group,
	pattern = "jumanji:///*",
	callback = function(args) require("jumanji.diff").read(args.buf) end,
})
vim.api.nvim_create_autocmd("BufWinEnter", {
	group = read_group,
	pattern = "jumanji:///*",
	callback = function(args) require("jumanji.diff").on_win_enter(args.buf) end,
})
vim.api.nvim_create_autocmd("BufReadCmd", {
	group = read_group,
	pattern = "jumanji://show/*",
	callback = function(args) require("jumanji.diff").read_show(args.buf) end,
})
vim.api.nvim_create_autocmd("BufReadCmd", {
	group = read_group,
	pattern = "jumanji://log/*",
	callback = function(args) require("jumanji").read(args.buf) end,
})

local snapshot_group = vim.api.nvim_create_augroup("jumanji-snapshot", { clear = true })
vim.api.nvim_create_autocmd("BufWritePost", {
	group = snapshot_group,
	callback = function(args)
		if package.loaded.jumanji then require("jumanji").snapshot(vim.fs.abspath(args.file)) end
	end,
})
vim.api.nvim_create_autocmd("FocusGained", {
	group = snapshot_group,
	callback = function()
		if package.loaded.jumanji then require("jumanji").snapshot() end
	end,
})

vim.api.nvim_create_user_command("J", function(opts)
	require("jumanji.cmd").run(opts.args)
end, {
	nargs = "*",
	complete = function(...) return require("jumanji.cmd").complete(...) end,
	desc = "Run jj; no args or `log [-r REVSET]` opens the log view",
})
