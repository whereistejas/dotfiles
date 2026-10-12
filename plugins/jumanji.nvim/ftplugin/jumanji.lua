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
map("p", function() require("jumanji").preview(false) end, "Preview diff in a split")
map("P", function() require("jumanji").preview(true) end, "Preview diff in a new tab")

vim.b.undo_ftplugin = "setlocal wrap< list< number< relativenumber< signcolumn< foldcolumn< cursorline<"
	.. " | silent! nunmap <buffer> q | silent! nunmap <buffer> R | silent! nunmap <buffer> l"
	.. " | silent! nunmap <buffer> h | silent! nunmap <buffer> p | silent! nunmap <buffer> P"
