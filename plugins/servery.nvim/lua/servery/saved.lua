local utils = require("servery.utils")
local pi_utils = require("servery.pi")

local M = {}

---@class servery.Saved
---@field name string
---@field cwd string
---@field saved_at integer
---@field pi { file: string, name: string?, title: string?, branch: string? }[]
---@field vim_file string

-- Runs in the server being saved. Only uses builtin APIs, since the server may
-- be running an old version of servery.
local mksession_code = [[
	local path = ...
	local old = vim.o.sessionoptions
	if not old:find("terminal", 1, true) then
		vim.o.sessionoptions = old == "" and "terminal" or (old .. ",terminal")
	end

	local ok, err = pcall(vim.api.nvim_command, "mksession! " .. vim.fn.fnameescape(path))
	vim.o.sessionoptions = old
	if not ok then
		error(err)
	end
]]

---@return string
local saved_dir = function() return vim.fs.normalize(require("servery").get_cfg().saved_dir) end

---@param name string
---@return string
local vim_file = function(name) return vim.fs.joinpath(saved_dir(), name .. ".vim") end

---@param name string
---@return string
local json_file = function(name) return vim.fs.joinpath(saved_dir(), name .. ".json") end

---@param name string
---@return boolean
local valid_name = function(name) return name ~= "" and not name:find("[/\\]") and not vim.startswith(name, ".") end

---@param socket string
---@param name string
local save_named = function(socket, name)
	if not valid_name(name) then
		utils.notify_error("Invalid session name '%s'", name)
		return
	end

	local chan = vim.fn.sockconnect("pipe", socket, { rpc = true })
	if chan == 0 then
		utils.notify_error("Could not connect to server at %s", socket)
		return
	end

	local ok, err = pcall(function()
		utils.mkdir(saved_dir())

		local cwd = vim.rpcrequest(chan, "nvim_call_function", "getcwd", {}) --[[@as string]]
		local info = vim.rpcrequest(chan, "nvim_exec_lua", pi_utils.remote_code, {})
		vim.rpcrequest(chan, "nvim_exec_lua", mksession_code, { vim_file(name) })

		local pis = {}
		for _, pi in ipairs(info.pi) do
			if pi.file and pi.status ~= "exited" then
				table.insert(pis, { file = pi.file, name = pi.name, title = pi.title, branch = pi.branch })
			end
		end

		local json = vim.json.encode({ name = name, cwd = cwd, saved_at = os.time(), pi = pis })
		assert(vim.fn.writefile({ json }, json_file(name)) == 0, "Failed to write " .. json_file(name))

		vim.rpcrequest(chan, "nvim_exec_lua", "vim.g.servery_name = ...", { name })
	end)
	vim.fn.chanclose(chan)

	if ok then
		utils.notify_info("Saved session '%s'", name)
	else
		utils.notify_error("Failed to save session '%s': %s", name, err)
	end
end

---Save the nvim at `socket` (default: this one) under a name, which defaults
---to its `g:servery_name`. When saving this nvim and it has no name, the name
---is asked for.
---@param opts? { name: string?, socket: string? }
M.save = function(opts)
	opts = opts or {}
	local socket = opts.socket or vim.v.servername
	local name = opts.name

	if not name then
		local chan = vim.fn.sockconnect("pipe", socket, { rpc = true })
		if chan == 0 then
			utils.notify_error("Could not connect to server at %s", socket)
			return
		end
		local current = vim.rpcrequest(chan, "nvim_exec_lua", "return vim.g.servery_name", {})
		vim.fn.chanclose(chan)
		name = type(current) == "string" and current ~= "" and current or nil
	end

	if name then
		save_named(socket, name)
	elseif socket == vim.v.servername then
		vim.ui.input({ prompt = "Save session as: " }, function(input)
			if input and input ~= "" then
				save_named(socket, input)
			end
		end)
	else
		utils.notify_error("Session has no name. Give one with :SvSave <name>")
	end
end

---List saved sessions, newest first
---
---@param opts? { closed: boolean? }
---@return servery.Saved[]
M.list = function(opts)
	opts = opts or {}
	local out = {} --[[@as servery.Saved[] ]]

	local running = {}
	if opts.closed then
		for _, session in ipairs(require("servery").list_sessions("active")) do
			if session.server.name then
				running[session.server.name] = true
			end
		end
	end

	if vim.uv.fs_stat(saved_dir()) then
		for file, kind in vim.fs.dir(saved_dir()) do
			local name = kind == "file" and file:match("^(.+)%.json$")
			if name and not running[name] and vim.uv.fs_stat(vim_file(name)) then
				local ok, saved = pcall(function()
					return vim.json.decode(table.concat(vim.fn.readfile(json_file(name)), "\n"))
				end)
				if ok and type(saved) == "table" and saved.cwd then
					table.insert(out, {
						name = name,
						cwd = saved.cwd,
						saved_at = saved.saved_at or 0,
						pi = saved.pi or {},
						vim_file = vim_file(name),
					})
				end
			end
		end
	end

	table.sort(out, function(a, b) return a.saved_at > b.saved_at end)

	return out
end

---Open a saved session in a new nvim, and switch to it
---@param name string
M.restore = function(name)
	for _, session in ipairs(require("servery").list_sessions("active")) do
		if session.server.name == name then
			utils.notify_error("Session '%s' is already running", name)
			return
		end
	end

	local saved = vim.iter(M.list()):find(function(s) return s.name == name end) --[[@as servery.Saved?]]
	if not saved then
		utils.notify_error("No saved session '%s'", name)
		return
	end

	local server = spawn_nvim(saved.cwd, {
		"--cmd",
		"let g:servery_name = " .. vim.fn.string(name),
		"-S",
		saved.vim_file,
	})
	utils.switch_to(server)
end

---@param name string
M.delete = function(name)
	if not valid_name(name) then
		return
	end

	vim.fn.delete(vim_file(name))
	vim.fn.delete(json_file(name))
end

return M
