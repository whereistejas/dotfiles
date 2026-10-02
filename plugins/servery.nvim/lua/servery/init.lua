local utils = require("servery.utils")

local M = {}

---@alias servery.ui_provider "builtin" | "snacks" | "fzf" | "telescope" | "mini_pick"
---@alias servery.action "switch" | "switch_and_detach" | "spawn" | "detach"

---@param opts { count: integer?, name: string?, status: ("any" | "active" | "inactive")? }
---@return servery.Session?
local get_session = function(opts)
	local sessions = M.list_sessions(opts.status)

	if opts.count then
		local servers = vim.tbl_filter(
			function(session) return session.server and session.server.socket ~= vim.v.servername or false end,
			sessions
		)
		local out = servers[opts.count]
		if not out then
			utils.notify_error(
				"Could not get last server #%d. Only found %d other servers running",
				opts.count,
				#servers
			)
		end
		return out
	end

	if opts.name then
		---@diagnostic disable-next-line: param-type-mismatch
		for _, session in ipairs(sessions) do
			if session:display_name() == opts.name then
				return session
			end
		end
	end
end

---@type table<string, vim.api.keyset.highlight>
local highlights = {
	ServeryLineCurrent = { link = "@keyword" },
	ServeryLineActive = { link = "NONE" },
	ServeryLineInactive = { link = "NONE" },
	ServeryIconCurrent = { link = "CursorLineNr" },
	ServeryIconActive = { link = "@label" },
	ServeryIconInactive = { link = "ComplHint" },
	ServeryTime = { link = "Comment" },
}

local set_highlights = function()
	for group, hl in pairs(highlights) do
		hl.default = true
		vim.api.nvim_set_hl(0, group, hl)
	end
end

local setup_cmds = function()
	vim.api.nvim_create_user_command("Sv", function(args)
		local count = args.count ~= 0 and args.count or nil
		local arg = args.fargs[1]
		local bang = args.bang

		assert(not (count and arg), "Cannot combine forms `:[N]Sv` and `:Sv [dir]`")

		if count or arg then
			local session = get_session({ count = count, name = arg })
			if session then
				session:switch()
			elseif arg then
				local stat = vim.uv.fs_stat(vim.fs.normalize(arg))
				if stat and stat.type == "directory" then
					utils.switch_to(spawn_nvim(arg), bang)
				else
					utils.notify_error("No such directory found '%s'", arg)
				end
			end
		else
			M.show_ui()
		end
	end, {
		nargs = "?",
		count = true,
		bang = true,
		complete = function()
			return vim.tbl_map(function(session) return session:display_name() end, M.list_sessions())
		end,
	})

	vim.api.nvim_create_user_command("SvStop", function(args)
		local count = args.count ~= 0 and args.count or nil
		local arg = args.fargs[1]

		assert(not (count and arg), "Cannot combine forms `:[N]SvStop` and `:SvStop [server]`")

		if count or arg then
			local session = get_session({ count = count, name = arg, only_running = true })
			if session then
				session:detach()
			elseif arg then
				utils.notify_error("No such running server found '%s'", arg)
			end
		end
	end, {
		nargs = "?",
		count = true,
		bang = true,
		complete = function()
			return vim.tbl_map(function(session) return session:display_name() end, M.list_sessions("active"))
		end,
	})
end

cfg_defaults = function()
	local cache_dir = vim.fn.stdpath("cache")
	assert(type(cache_dir) == "string")

	---@class servery.Cfg
	local out = {
		---@type string[] | fun(): string[]
		dirs = function() return vim.fs.glob("~/*", true, true) end,
		servers = function() return vim.fs.glob("~/*", true, true) end,
		session_dir = vim.fs.joinpath(cache_dir, "servery.nvim"),
		---@type string[]
		spawn_cmd = { vim.v.progpath },
		ui = {
			provider = "builtin", ---@type servery.ui_provider
			prompt = "Switch Nvim Session",
			icons = {
				current = "",
				active = "",
				inactive = "",
			},
			---@type table<string, servery.action>
			actions = {
				["<enter>"] = "switch",
				["<c-g>"] = "switch_and_detach",
				["<c-x>"] = "detach",
				["<c-s>"] = "spawn",
			},
			---@type table<string, servery.action>
			fzf_actions = {
				["enter"] = "switch",
				["ctrl-g"] = "switch_and_detach",
				["ctrl-x"] = "detach",
				["ctrl-s"] = "spawn",
			},
		},
	}

	return out
end

M.cfg = nil --[[@as servery.Cfg?]]

---@param opts? servery.Cfg | {}
M.setup = function(opts)
	if not M.cfg then
		M.cfg = vim.tbl_deep_extend("force", cfg_defaults(), opts or {})
		vim.g.servery_original_cwd = vim.fn.getcwd()

		set_highlights()
		vim.api.nvim_create_autocmd("ColorScheme", { callback = set_highlights })

		require("servery.utils").mkdir(M.cfg.session_dir)
		setup_cmds()
	end
end

---@return servery.Cfg
M.get_cfg = function()
	assert(M.cfg, "Config is empty. Please call servery.setup()")
	return M.cfg
end

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
	local cfg = M.get_cfg()
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

function Session:detach()
	if not self.server then
		return
	end

	local chan = vim.fn.sockconnect("pipe", self.server.socket, { rpc = true })

	local unsaved = vim.rpcrequest(
		chan,
		"nvim_exec_lua",
		[[
			return vim.tbl_filter(
				function(b) return vim.bo[b.bufnr].buftype == "" end,
				vim.fn.getbufinfo({ bufmodified = 1 })
			)
		]],
		{}
	) --[[@as table[] ]]

	if #unsaved > 0 then
		local names = vim.tbl_map(function(b) return "`" .. vim.fn.fnamemodify(b.name, ":~:.") .. "`" end, unsaved)
		local check = table.concat(names, ", ")
		utils.notify_warn("Can't close session '%s' due to unsaved changes. Check %s", self:display_name(), check)
	else
		-- Slightly defer the :qall so we have time to close the channel, rather
		-- than having it forcibly closed and show an annoying message
		vim.rpcrequest(chan, "nvim_exec_lua", "vim.defer_fn(vim.cmd.qall, 100)", {})
	end

	vim.fn.chanclose(chan)
end

---@class servery.ServerInfo
---@field socket string
---@field pid integer
---@field original_cwd string?
---@field useractive integer?
---@field starttime integer?

---A neovim session may move to a different cwd, e.g. using :cd. servery.nvim
---keeps a record of where the session originally started, e.g. session name
---doesn't change too much in the UI.
---
---Currently gets cleared on :restart unless `globals` appears in
---'sessionoptions'.
---
---@return string
M.cwd = function() return vim.g.servery_original_cwd or vim.fn.getcwd() end

local nilify = function(x) return not x == vim.NIL and x end

---@return servery.SessionActive
local get_server_info = function(server)
	local chan = vim.fn.sockconnect("pipe", server, { rpc = true })
	assert(chan ~= 0, "Could not connect to server at " .. server)

	local out = Session.new(vim.rpcrequest(chan, "nvim_call_function", "getcwd", {})--[[@as string]], {
		socket = server,
		pid = vim.rpcrequest(chan, "nvim_call_function", "getpid", {}) --[[@as integer]],
		useractive = vim.fn.has("nvim-0.13") == 1 and vim.rpcrequest(chan, "nvim_get_vvar", "useractive") or nil --[[@as integer?]],
		starttime = vim.fn.has("nvim-0.13") == 1 and vim.rpcrequest(chan, "nvim_get_vvar", "starttime") or nil --[[@as integer?]],
		original_cwd = nilify(vim.rpcrequest(
			chan,
			"nvim_exec_lua",
			[[
				local ok, cwd = pcall(function() require("servery").cwd() end)
				return ok and cwd or nil
			]],
			{}
		)) --[[@as string?]],
	})
	vim.fn.chanclose(chan)
	return out
end

---List running servers
---
---@return servery.SessionActive[]
list_servers = function()
	local servers = vim.fn.serverlist({ peer = true }) --[[@as string[] ]]

	local out = {}

	for _, server in ipairs(servers) do
		-- See :h serverstart
		-- serverstart() generates names like:
		--   stdpath("run").."/{name}.{pid}.{counter}"
		-- {name} is "nvim" for servers which are generated normally (i.e. by
		-- starting nvim). Processes which embed nvim, however, (should) use
		-- a different {name}. We don't want to surface embedded nvim sessions
		-- to the user.
		local name = vim.fs.basename(server):match("(.+)%.[^.]+%.[^.]+$")
		if name == "nvim" then
			table.insert(out, server)
		end
	end

	for name, type in vim.fs.dir(M.get_cfg().session_dir) do
		if type == "socket" then
			local server = vim.fs.joinpath(M.get_cfg().session_dir, name)
			if not vim.tbl_contains(out, server) then
				table.insert(out, server)
			end
		end
	end

	return vim.tbl_map(get_server_info, out)
end

---List configured session directories
---
---@return servery.Session[]
list_dirs = function()
	local cfg = M.get_cfg()
	local dirs = type(cfg.dirs) == "table" and cfg.dirs or cfg.dirs()
	return vim.tbl_map(Session.new, dirs)
end

---List the sessions discoverable by servery
---
---@param status? "any" | "active" | "inactive"
---@return servery.Session[]
M.list_sessions = function(status)
	status = status or "any"
	local out = {} --[[@as servery.Session[] ]]

	if status == "any" or status == "active" then
		vim.list_extend(out, list_servers())
	end

	if status == "any" or status == "inactive" then
		vim.list_extend(out, list_dirs())
	end

	table.sort(out, function(a, b)
		if a.server and not b.server then
			return true
		end

		if b.server and not a.server then
			return false
		end

		if a.server and b.server then
			if a.server.socket == vim.v.servername then
				return true
			end

			if b.server.socket == vim.v.servername then
				return false
			end

			local sort_by = vim.fn.has("nvim-0.13") == 1 and "useractive" or "pid"

			return a.server[sort_by] > b.server[sort_by]
		end

		return a.cwd < b.cwd
	end)

	return out
end

---@param provider? servery.ui_provider
M.show_ui = function(provider)
	provider = provider or M.get_cfg().ui.provider
	require("servery.ui." .. provider).select()
end

---@return string
spawn_nvim = function(dir)
	dir = vim.fs.normalize(dir)
	local stat = vim.uv.fs_stat(dir)
	assert(stat and stat.type == "directory", string.format("`%s` is not a directory", dir))

	local server_name = vim.fs.basename(dir) .. os.date("%Y%m%d-%H%M%S") .. ".pipe"
	local server_file = vim.fs.joinpath(M.get_cfg().session_dir, server_name)
	local cmd = vim.list_extend(vim.deepcopy(M.get_cfg().spawn_cmd), { "--headless", "--listen", server_file })
	local cmd_str = table.concat(cmd, " ")

	local chan = vim.fn.jobstart(cmd, { detach = true, cwd = dir })

	if chan == 0 or chan == -1 then
		error(string.format("Failed to spawn nvim with command `%s`", cmd_str))
	end

	return server_file
end

---@param opts { dir: string?, server: string? }
---@param detach boolean?
connect = function(opts, detach)
	assert(opts.dir or opts.server, "Must supply `dir` or `server`")
	utils.switch_to(opts.server or spawn_nvim(opts.dir), detach)
end

return M
