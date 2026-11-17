local M = {}

local function runs_pi(cmd)
	local program = cmd and cmd:match("^%S+")
	return program ~= nil and vim.fs.basename(program) == "pi"
end

--- The directory pi runs in, if `buf` is a terminal running pi. Neovim names
--- a terminal buffer term://<job cwd>//<pid>:<command>, with the command's
--- program resolved to its path when started from an argument list.
---@param buf integer? defaults to the current buffer
---@return string?
function M.cwd(buf)
	buf = buf or 0
	if vim.bo[buf].buftype ~= "terminal" then return nil end

	local cwd, cmd = vim.api.nvim_buf_get_name(buf):match("^term://(.-)//%d+:(.*)$")
	if not runs_pi(cmd) then return nil end
	return cwd
end

--- Start the pi terminals a session restored as unloaded buffers. :mksession
--- saves a hidden terminal as a bare `badd term://…`, whose job only starts
--- once the buffer is shown. A shown terminal leaves an unlisted, unloaded
--- buffer behind when the session renames it back to its saved name.
--- Terminals whose directory is gone stay unstarted, with one short warning:
--- a long or failing message here blocks the session on a hit-enter prompt.
function M.resume_hidden()
	local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
	local gone = 0
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local name, cmd = vim.api.nvim_buf_get_name(buf):match("^term://(.-)//%d+:(.*)$")
		local cwd = name and vim.fs.normalize(name)
		local hidden_pi = vim.bo[buf].buflisted and not vim.api.nvim_buf_is_loaded(buf) and runs_pi(cmd)
		if hidden_pi and vim.fn.isdirectory(cwd) == 0 then
			gone = gone + 1
		elseif hidden_pi then
			-- Loading runs nvim's term:// BufReadCmd, which would start the job in
			-- the 5-row autocmd window; pi's TUI redraws its whole history on every
			-- frame at that height. A b:term_title makes it skip the buffer.
			vim.b[buf].term_title = cmd
			vim.fn.bufload(buf)
			vim.api.nvim_buf_call(buf, function()
				vim.fn.jobstart(cmd, { term = true, cwd = cwd, width = info.width - info.textoff, height = info.height })
			end)
		end
	end

	if gone > 0 then
		local noun = gone == 1 and "terminal whose directory is" or "terminals whose directories are"
		vim.notify(("pi: not resuming %d %s gone"):format(gone, noun), vim.log.levels.WARN)
	end
end

--- The root of the jj workspace pi runs in, if `buf` is a terminal running pi.
---@param buf integer? defaults to the current buffer
---@return string?
function M.root(buf)
	local cwd = M.cwd(buf)
	return cwd and vim.fs.root(cwd, ".jj")
end

local function running(buf)
	return M.cwd(buf) ~= nil and vim.fn.jobwait({ vim.bo[buf].channel }, 0)[1] == -1
end

--- The running pi terminal to act on: the current buffer, else one shown in the
--- current tab, else the most recently used one.
---@return integer?
function M.target()
	local current = vim.api.nvim_get_current_buf()
	if running(current) then return current end

	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local buf = vim.api.nvim_win_get_buf(win)
		if running(buf) then return buf end
	end

	local latest
	for _, info in ipairs(vim.fn.getbufinfo({ bufloaded = 1 })) do
		if running(info.bufnr) and (not latest or info.lastused > latest.lastused) then latest = info end
	end
	return latest and latest.bufnr
end

-- Show the buffer: in its window in the current tab, else in the current window.
local function focus(buf)
	local tab_wins = vim.api.nvim_tabpage_list_wins(0)
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		if vim.list_contains(tab_wins, win) then
			vim.api.nvim_set_current_win(win)
			return
		end
	end
	vim.api.nvim_win_set_buf(0, buf)
end

--- Type a slash command into the target pi terminal and focus it, in terminal
--- mode. Text already in pi's editor stays, so the command is appended to it.
---@param cmd string the command without its slash, e.g. "tree"; "" only focuses
function M.command(cmd)
	local buf = M.target()
	if not buf then
		vim.notify("pi: no running pi terminal", vim.log.levels.ERROR)
		return
	end

	if cmd ~= "" then vim.fn.chansend(vim.bo[buf].channel, "/" .. cmd .. "\r") end
	focus(buf)
	vim.cmd.startinsert()
end

return M
