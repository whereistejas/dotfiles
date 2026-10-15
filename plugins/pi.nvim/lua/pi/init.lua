local M = {}

--- The directory pi runs in, if `buf` is a terminal running pi. Neovim names
--- a terminal buffer term://<job cwd>//<pid>:<command>, with the command's
--- program resolved to its path when started from an argument list.
---@param buf integer? defaults to the current buffer
---@return string?
function M.cwd(buf)
	buf = buf or 0
	if vim.bo[buf].buftype ~= "terminal" then return nil end

	local cwd, cmd = vim.api.nvim_buf_get_name(buf):match("^term://(.-)//%d+:(.*)$")
	local program = cmd and cmd:match("^%S+")
	if not program or vim.fs.basename(program) ~= "pi" then return nil end
	return cwd
end

--- The root of the jj workspace pi runs in, if `buf` is a terminal running pi.
---@param buf integer? defaults to the current buffer
---@return string?
function M.root(buf)
	local cwd = M.cwd(buf)
	return cwd and vim.fs.root(cwd, ".jj")
end

return M
