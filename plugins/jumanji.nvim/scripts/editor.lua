-- jj's editor ($JJ_EDITOR) for commands run with :J. Run as
-- `nvim --clean -l editor.lua <file>`: opens <file> in the Neovim that started
-- jj ($NVIM) and returns once that buffer is gone, i.e. its window was closed.
local file = vim.fn.fnamemodify(arg[1], ":p")
local chan = vim.fn.sockconnect("pipe", vim.env.NVIM, { rpc = true })

vim.rpcrequest(chan, "nvim_exec_lua", "require('jumanji.cmd').edit(...)", { file })
vim.wait(24 * 60 * 60 * 1000, function()
	return vim.rpcrequest(chan, "nvim_call_function", "bufexists", { file }) == 0
end, 200)
