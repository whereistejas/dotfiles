local M = {}

local tests = {} --[[@as { name: string, fn: fun() }[] ]]

---@param name string
---@param fn fun()
M.test = function(name, fn) table.insert(tests, { name = name, fn = fn }) end

M.eq = function(expected, actual, msg)
	if not vim.deep_equal(expected, actual) then
		error(
			string.format("%sexpected %s, got %s", msg and (msg .. ": ") or "", vim.inspect(expected), vim.inspect(actual)),
			2
		)
	end
end

M.truthy = function(x, msg)
	if not x then
		error(msg or "expected a truthy value", 2)
	end
end

-- Sockets live under /tmp because macOS limits socket paths to 104 bytes
local root = "/tmp/sv-test-" .. vim.fn.getpid()

local real_cmd = vim.cmd
local real_notify = vim.notify

---@class servery.test.State
---@field connects { server: string, bang: boolean }[]
---@field quits string[]
---@field notes { msg: string, level: integer? }[]
---@field dir string
---@field spawned string[]
local state

---Make a directory for a test session. The first 5 letters of the name are
---used for the socket name, so keep them distinct within a test.
---@param name string
---@return string
M.dir = function(name)
	local dir = vim.fs.joinpath(state.dir, "dirs", name)
	vim.fn.mkdir(dir, "p")
	return vim.uv.fs_realpath(dir) --[[@as string]]
end

---@return string
M.session_dir = function() return vim.fs.joinpath(state.dir, "sessions") end

---@return string
M.saved_dir = function() return vim.fs.joinpath(state.dir, "saved") end

---@param opts? table
M.setup = function(opts)
	local servery = require("servery")
	servery.cfg = nil
	servery.setup(vim.tbl_deep_extend("force", {
		dirs = {},
		-- Never discover the user's own nvims
		servers = function() return {} end,
		session_dir = M.session_dir(),
		saved_dir = M.saved_dir(),
		spawn_cmd = { vim.v.progpath, "--clean" },
	}, opts or {}))
end

---Start a headless nvim in `dir` the way servery does, and wait for it
---@param dir string
---@param extra_args? string[]
---@return string socket
M.spawn = function(dir, extra_args)
	local socket = spawn_nvim(dir, extra_args)
	table.insert(state.spawned, socket)
	M.truthy(M.wait_running(socket), "server never started at " .. socket)
	return socket
end

---@param socket string
---@return boolean
M.is_running = function(socket)
	local ok, chan = pcall(vim.fn.sockconnect, "pipe", socket, { rpc = true })
	if not ok or chan == 0 then
		return false
	end
	local alive = pcall(vim.rpcrequest, chan, "nvim_get_api_info")
	pcall(vim.fn.chanclose, chan)
	return alive
end

M.wait_running = function(socket)
	return vim.wait(3000, function() return M.is_running(socket) end, 20)
end

M.wait_stopped = function(socket)
	return vim.wait(3000, function() return not M.is_running(socket) end, 20)
end

---Run Lua in another nvim
---@param socket string
---@param code string
---@param args? any[]
M.remote = function(socket, code, args)
	local chan = vim.fn.sockconnect("pipe", socket, { rpc = true })
	local out = vim.rpcrequest(chan, "nvim_exec_lua", code, args or {})
	vim.fn.chanclose(chan)
	return out
end

---@return servery.test.State
M.state = function() return state end

---The `:connect` calls made so far
---@return { server: string, bang: boolean }[]
M.connects = function() return state.connects end

---Notifications at `level` or above
---@param level integer
---@return string[]
M.notes = function(level)
	return vim.iter(state.notes)
		:filter(function(n) return (n.level or 0) >= level end)
		:map(function(n) return n.msg end)
		:totable()
end

local cmd_name = function(cmd) return type(cmd) == "table" and cmd.cmd or vim.split(vim.trim(cmd), "%s")[1] end

-- `:connect` needs a UI and `:qall` would end the test run, so record them
-- instead of running them
local fake_cmd = setmetatable({}, {
	__call = function(_, cmd)
		local name = cmd_name(cmd)
		if name == "connect" then
			table.insert(state.connects, { server = cmd.args[1], bang = cmd.bang == true })
		elseif name and name:match("^qa") then
			table.insert(state.quits, type(cmd) == "table" and (cmd.cmd .. (cmd.bang and "!" or "")) or vim.trim(cmd))
		else
			return real_cmd(cmd)
		end
	end,
	__index = function(t, name)
		return function(...)
			local args = { ... }
			if name == "connect" or name:match("^qa") then
				return t({ cmd = name, args = args })
			end
			return real_cmd[name](...)
		end
	end,
})

local before = function()
	state = { connects = {}, quits = {}, notes = {}, spawned = {}, dir = vim.fs.joinpath(root, tostring(vim.uv.hrtime())) }
	vim.fn.mkdir(state.dir, "p")
	vim.cmd = fake_cmd
	vim.notify = function(msg, level) table.insert(state.notes, { msg = msg, level = level }) end
	vim.g.servery_name = nil
	M.setup()
end

local after = function()
	vim.cmd = real_cmd
	vim.notify = real_notify

	for name, kind in vim.fs.dir(M.session_dir()) do
		if kind == "socket" then
			table.insert(state.spawned, vim.fs.joinpath(M.session_dir(), name))
		end
	end
	for _, socket in ipairs(state.spawned) do
		if M.is_running(socket) then
			pcall(M.remote, socket, "vim.defer_fn(function() vim.cmd('qall!') end, 10)")
		end
	end
	for _, socket in ipairs(state.spawned) do
		M.wait_stopped(socket)
	end

	-- Modified buffers would leak into the next test
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.bo[buf].modified then
			vim.bo[buf].modified = false
		end
	end
	real_cmd("silent! %bwipeout!")
end

---@param filter? string Only run tests whose name contains this
M.run = function(filter)
	local failed = 0
	local ran = 0
	for _, t in ipairs(tests) do
		if not filter or t.name:find(filter, 1, true) then
			ran = ran + 1
			before()
			local ok, err = xpcall(t.fn, debug.traceback)
			after()
			if ok then
				print("ok   " .. t.name)
			else
				failed = failed + 1
				print("FAIL " .. t.name .. "\n" .. err:gsub("\n", "\n     ") .. "\n")
			end
		end
	end
	vim.fn.delete(root, "rf")

	print(string.format("\n%d passed, %d failed", ran - failed, failed))
	return failed == 0
end

return M
