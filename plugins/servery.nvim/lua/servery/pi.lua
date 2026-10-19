local utils = require("servery.utils")

local M = {}

---@class servery.Pi
---@field buf integer
---@field status "running" | "idle" | "unknown" | "exited"
---@field file string?
---@field id string?
---@field name string?
---@field title string?
---@field branch string?
---@field tab integer?
---@field win integer?

-- Runs in each server to find its name and pi terminals. Only uses builtin
-- APIs, since the server may be running an old version of servery.
M.remote_code = [[
	local str = function(x) return type(x) == "string" and x ~= "" and x or nil end

	local shown, order = {}, {}
	for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
		local tabnr = vim.api.nvim_tabpage_get_number(tab)
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
			local buf = vim.api.nvim_win_get_buf(win)
			if not shown[buf] then
				shown[buf] = { tab = tabnr, win = win }
				table.insert(order, buf)
			end
		end
	end
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if not shown[buf] then
			table.insert(order, buf)
		end
	end

	-- pi names its process "pi", whether it was started as `pi`, `node cli.js`
	-- or from a shell
	local runs_pi
	runs_pi = function(pid, depth)
		local proc = vim.api.nvim_get_proc(pid)
		if proc and proc.name == "pi" then
			return true
		end
		if depth > 0 then
			for _, child in ipairs(vim.api.nvim_get_proc_children(pid)) do
				if runs_pi(child, depth - 1) then
					return true
				end
			end
		end
		return false
	end

	local session_arg = function(cmd)
		return cmd:match("%-%-session%s+'([^']*)'")
			or cmd:match('%-%-session%s+"([^"]*)"')
			or cmd:match("%-%-session%s+(%S+)")
	end

	local pis = {}
	for _, buf in ipairs(order) do
		if vim.bo[buf].buftype == "terminal" then
			local _, cmd = vim.api.nvim_buf_get_name(buf):match("^term://(.-)//%d+:(.*)$")
			local program = cmd and cmd:match("^%S+")
			local session = vim.b[buf].pi_session
			if type(session) ~= "table" then
				session = nil
			end

			local is_pi = session ~= nil or (program ~= nil and vim.fs.basename(program) == "pi")
			if not is_pi and vim.bo[buf].channel > 0 then
				local ok, pid = pcall(vim.fn.jobpid, vim.bo[buf].channel)
				is_pi = ok and runs_pi(pid, 3)
			end

			if is_pi then
				session = session or {}
				local channel = vim.bo[buf].channel
				local alive = channel > 0 and vim.fn.jobwait({ channel }, 0)[1] == -1
				local status = session.status
				if not alive then
					status = "exited"
				elseif status ~= "running" and status ~= "idle" then
					status = "unknown"
				end

				local title = str(vim.b[buf].term_title)
				if title and vim.startswith(title, "term://") then
					title = nil
				end

				table.insert(pis, {
					buf = buf,
					status = status,
					file = str(session.file) or (cmd and session_arg(cmd)),
					id = str(session.id),
					name = str(session.name),
					title = title,
					branch = str(vim.b[buf].pi_branch),
					tab = shown[buf] and shown[buf].tab,
					win = shown[buf] and shown[buf].win,
				})
			end
		end
	end

	return { name = str(vim.g.servery_name), pi = pis }
]]

-- Runs in the server to go to a pi terminal
local focus_code = [[
	local buf = ...
	for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
			if vim.api.nvim_win_get_buf(win) == buf then
				vim.api.nvim_set_current_tabpage(tab)
				vim.api.nvim_set_current_win(win)
				return true
			end
		end
	end

	if not vim.api.nvim_buf_is_valid(buf) then
		return false
	end
	vim.cmd("tab sbuffer " .. buf)
	return true
]]

-- Spinner frames are braille characters
local spinner = "^\xE2[\xA0-\xA3][\x80-\xBF]%s+"

local separators = { "-", "–", "—", "|", ":" }

---A short description of a pi terminal: its title without the spinner, the
---"π — " prefix, or a trailing " — <dir>", else the pi session name or file.
---@param pi servery.Pi
---@param cwd? string
---@return string
M.label = function(pi, cwd)
	local title = pi.title
	if title then
		title = title:gsub(spinner, ""):gsub("^π", "")
		for _, sep in ipairs(separators) do
			title = title:gsub("^%s+" .. vim.pesc(sep) .. "%s+", "", 1)
		end
		if cwd then
			local dir = vim.pesc(vim.fs.basename(cwd))
			for _, sep in ipairs(separators) do
				title = title:gsub("%s+" .. vim.pesc(sep) .. "%s+" .. dir .. "$", "")
			end
		end
		title = vim.trim(title)
		if title ~= "" and title ~= "π" then
			return title
		end
	end

	if pi.name then
		return pi.name
	end

	if pi.file then
		return (vim.fs.basename(pi.file):gsub("%.jsonl$", ""))
	end

	return "pi"
end

---Make the pi terminal the current buffer of the session's nvim, in the
---window and tab that show it if there is one.
---@param session servery.SessionActive
---@param pi servery.Pi
M.focus = function(session, pi)
	local chan = vim.fn.sockconnect("pipe", session.server.socket, { rpc = true })
	assert(chan ~= 0, "Could not connect to server at " .. session.server.socket)

	local ok, found = pcall(vim.rpcrequest, chan, "nvim_exec_lua", focus_code, { pi.buf })
	vim.fn.chanclose(chan)

	if not ok then
		utils.notify_error("Failed to go to pi terminal: %s", found)
		return false
	elseif not found then
		utils.notify_error("The pi terminal no longer exists")
		return false
	end

	return true
end

---Go to the pi terminal, switching to its nvim session if it's not this one.
---@param session servery.SessionActive
---@param pi servery.Pi
M.jump = function(session, pi)
	if M.focus(session, pi) and session.server.socket ~= vim.v.servername then
		session:switch()
	end
end

return M
