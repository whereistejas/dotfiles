if vim.b.did_ftplugin then return end
vim.b.did_ftplugin = 1

vim.opt_local.wrap = false
vim.opt_local.list = false
vim.opt_local.number = false
vim.opt_local.relativenumber = false
vim.opt_local.signcolumn = "no"
vim.opt_local.foldcolumn = "0"
vim.opt_local.cursorline = true

local function map(lhs, rhs, desc)
	vim.keymap.set("n", lhs, rhs, { buffer = true, desc = desc })
end

map("q", "<Cmd>bdelete<CR>", "Close jumanji log")
map("R", "<Cmd>edit<CR>", "Refresh jumanji log")
map("l", function() require("jumanji").expand() end, "Expand commit")
map("h", function() require("jumanji").collapse() end, "Collapse commit")
map("o", function() require("jumanji").open_diff(false) end, "Diff file in a split")
map("O", function() require("jumanji").open_diff(true) end, "Diff file in a new tab")

vim.b.undo_ftplugin = "setlocal wrap< list< number< relativenumber< signcolumn< foldcolumn< cursorline<"
	.. " | silent! nunmap <buffer> q | silent! nunmap <buffer> R | silent! nunmap <buffer> l"
	.. " | silent! nunmap <buffer> h | silent! nunmap <buffer> o | silent! nunmap <buffer> O"
