local utils = require("servery.utils")

---Active sessions include the `server` field, inactive ones don't.
---
---@class servery.Session
---@field cwd string
---@field server servery.ServerInfo?
local Session = {}
Session.__index = Session

---@class servery.SessionActive : servery.Session
---@field server servery.ServerInfo

---@param cwd string
---@param server servery.ServerInfo
Session.new = function(cwd, server)
	--
	return setmetatable({ cwd = cwd, server = server }, Session)
end

function Session:status()
	local socket = self.server and self.server.socket
	if socket == vim.v.servername then
		return "Current"
	elseif socket then
		return "Active"
	else
		return "Inactive"
	end
end

function Session:icon()
	local cfg = require("servery").get_cfg()
	return cfg.ui.icons[string.lower(self:status())] or " "
end

---@param as_of? integer
---@return string?
function Session:time_since_start(as_of)
	if self.server and self.server.starttime then
		return "(" .. utils.time_since(self.server.starttime / 1e9, as_of) .. ")"
	end
end

-- TODO: warn unsaved files, etc?
---@param detach boolean?
function Session:switch(detach)
	connect({
		server = self.server and self.server.socket,
		dir = self.cwd,
	}, detach)
end

function Session:spawn_new() spawn_nvim(self.cwd) end

function Session:display_name()
	local dir = vim.fn.fnamemodify(self.cwd, ":~")
	if self:status() == "Inactive" then
		return dir
	else
		local curr_dir = vim.fs.basename(dir)
		local original_cwd = self.server and self.server.original_cwd
		if original_cwd and original_cwd ~= self.cwd then
			local original_dir = vim.fs.basename(vim.fn.fnamemodify(original_cwd, ":~"))
			return original_dir .. " ( " .. curr_dir .. ")"
		end
		return curr_dir
	end
end

---A short description of what the session is doing: the name set with
---`:SvName`, or the title of a terminal in the session, or the focused file.
---A trailing " - <dir>" is dropped since the directory is already shown.
---@return string?
function Session:title()
	local title = self.server and self.server.title
	if not title then
		return
	end
	local dir = vim.pesc(vim.fs.basename(self.cwd))
	for _, sep in ipairs({ "-", "–", "—", "|", ":" }) do
		title = title:gsub("%s+" .. vim.pesc(sep) .. "%s+" .. dir .. "$", "")
	end
	return title
end

---Text for pickers to match against: the display name plus the title
---@return string
function Session:search_text()
	local title = self:title()
	return self:display_name() .. (title and (" " .. title) or "")
end

---The name commands refer to the session by: its `:SvName`, else its display name
---@return string
function Session:name() return self.server and self.server.name or self:display_name() end

---@param code string
---@return any
function Session:exec_lua(code)
	local chan = vim.fn.sockconnect("pipe", self.server.socket, { rpc = true })
	local out = vim.rpcrequest(chan, "nvim_exec_lua", code, {})
	vim.fn.chanclose(chan)
	return out
end

---@return string[]
function Session:unsaved_files()
	return self:exec_lua([[
		local files = {}
		for _, b in ipairs(vim.fn.getbufinfo({ bufmodified = 1 })) do
			if vim.bo[b.bufnr].buftype == "" then
				table.insert(files, vim.fn.fnamemodify(b.name, ":~:."))
			end
		end
		return files
	]])
end

---Stop the session, unless it has unsaved changes and `force` isn't set. The
---UI attached to the current session moves to another running session first.
---@param force boolean?
function Session:stop(force)
	if not self.server then
		return
	end

	local unsaved = force == true and {} or self:unsaved_files()
	if #unsaved > 0 then
		local names = vim.tbl_map(function(f) return "`" .. f .. "`" end, unsaved)
		utils.notify_error(
			"Can't close session '%s' due to unsaved changes. Check %s",
			self:name(),
			table.concat(names, ", ")
		)
		return
	end

	if self:status() == "Current" then
		local next_session = vim.iter(require("servery").list_sessions("active")):find(
			function(session) return session:status() ~= "Current" end
		)
		if next_session then
			utils.switch_to(next_session.server.socket, true)
		else
			vim.cmd("qall!")
		end
		return
	end

	-- Defer the :qall so the request returns before the channel closes
	self:exec_lua("vim.defer_fn(function() vim.cmd('qall!') end, 10)")
	vim.wait(1000, function() return vim.uv.fs_stat(self.server.socket) == nil end, 10)
end

return Session
