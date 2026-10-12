if vim.b.did_ftplugin then return end
vim.b.did_ftplugin = 1

vim.opt_local.wrap = false
vim.opt_local.list = false
vim.opt_local.signcolumn = "auto"
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
map("e", function() require("jumanji").edit() end, "Edit commit (jj edit)")
map("o", function() require("jumanji").open_file(false) end, "Edit commit, open file in a split")
map("O", function() require("jumanji").open_file(true) end, "Edit commit, open file in a new tab")
map("B", function() require("jumanji").set_bookmark() end, "Move a bookmark here")
map("<Tab>", function() require("jumanji").toggle_select() end, "Select commit, move to next")
map("a", function() require("jumanji").abandon() end, "Abandon selected commits or the one under the cursor")

vim.b.undo_ftplugin = "setlocal wrap< list< signcolumn< foldcolumn< cursorline<"
	.. " | silent! nunmap <buffer> q | silent! nunmap <buffer> R | silent! nunmap <buffer> l"
	.. " | silent! nunmap <buffer> h | silent! nunmap <buffer> p | silent! nunmap <buffer> P"
	.. " | silent! nunmap <buffer> e | silent! nunmap <buffer> o | silent! nunmap <buffer> O"
	.. " | silent! nunmap <buffer> B | silent! nunmap <buffer> <Tab> | silent! nunmap <buffer> a"
