local M = {}

---@type string set by run.lua
M.plugin_root = nil

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
local root = "/tmp/jumanji-test-" .. vim.fn.getpid()

---@class jumanji.test.Nvim
---@field chan integer
---@field socket string

---@class jumanji.test.State
---@field dir string
---@field nvims jumanji.test.Nvim[]
local state

---Run jj in `dir`, failing the test if it fails
---@param dir string
---@param args string[]
---@return string stdout
M.jj = function(dir, args)
	local obj = vim.system(vim.list_extend({ "jj", "--no-pager", "--color=never" }, args), { cwd = dir, text = true }):wait()
	if obj.code ~= 0 then
		error(("jj %s failed: %s"):format(table.concat(args, " "), obj.stderr), 2)
	end
	return obj.stdout
end

---A repo with one commit and a second workspace, `other`
---@return { main: string, other: string }
M.repo = function()
	local main = vim.fs.joinpath(state.dir, "main")
	local other = vim.fs.joinpath(state.dir, "other")
	M.jj(state.dir, { "git", "init", main })
	main = vim.uv.fs_realpath(main) --[[@as string]]
	vim.fn.writefile({ "x" }, vim.fs.joinpath(main, "file"))
	M.jj(main, { "commit", "-m", "first" })
	M.jj(main, { "workspace", "add", other })
	return { main = main, other = vim.uv.fs_realpath(other) --[[@as string]] }
end

---Make the main workspace's working copy stale: rewrite its working-copy
---commit, with different files, from the other workspace
---@param repo { main: string, other: string }
M.make_stale = function(repo)
	vim.fn.writefile({ "y" }, vim.fs.joinpath(repo.main, "file"))
	M.jj(repo.main, { "util", "snapshot" })
	M.jj(repo.other, { "restore", "--from", "root()", "--into", "default@" })
end

---Start an nvim with jumanji loaded, in `dir`. A UI attaches and then
---detaches, as when servery leaves a session running in the background:
---from then on, a message that needs a hit-enter prompt blocks the nvim.
---@param dir string
---@return jumanji.test.Nvim
M.nvim = function(dir)
	local socket = vim.fs.joinpath(state.dir, "nvim-" .. #state.nvims .. ".sock")
	local chan = vim.fn.jobstart({
		vim.v.progpath, "--clean", "--embed", "--listen", socket,
		"--cmd", "set rtp^=" .. vim.fn.fnameescape(M.plugin_root),
	}, { rpc = true, cwd = dir })
	local nvim = { chan = chan, socket = socket }
	table.insert(state.nvims, nvim)

	M.truthy(vim.wait(3000, function() return vim.uv.fs_stat(socket) ~= nil end, 20), "nvim never listened on " .. socket)
	local ui = vim.fn.sockconnect("pipe", socket, { rpc = true })
	vim.rpcrequest(ui, "nvim_ui_attach", 80, 24, { ext_linegrid = true })
	M.truthy(vim.wait(3000, function() return vim.rpcrequest(chan, "nvim_get_vvar", "vim_did_enter") == 1 end, 20))
	vim.fn.chanclose(ui)
	M.truthy(vim.wait(3000, function() return #vim.rpcrequest(chan, "nvim_list_uis") == 0 end, 20))
	return nvim
end

---Fail if the nvim is stuck at a prompt. Requests other than "fast" ones like
---nvim_get_mode would hang the test until it's answered.
---@param nvim jumanji.test.Nvim
M.not_blocked = function(nvim)
	local mode = vim.rpcrequest(nvim.chan, "nvim_get_mode")
	if mode.blocking then
		error("nvim is blocked in mode " .. mode.mode .. ":\n" .. M.messages(nvim), 2)
	end
end

---Run Lua in the nvim
---@param nvim jumanji.test.Nvim
---@param code string
---@param args? any[]
M.lua = function(nvim, code, args)
	M.not_blocked(nvim)
	local out = vim.rpcrequest(nvim.chan, "nvim_exec_lua", code, args or {})
	if out == vim.NIL then return nil end
	return out
end

---Wait until Lua run in the nvim returns a truthy value, failing if the nvim
---blocks on a prompt meanwhile
---@param nvim jumanji.test.Nvim
---@param code string
---@param args? any[]
---@return any
M.wait_for = function(nvim, code, args)
	local out
	vim.wait(5000, function()
		out = M.lua(nvim, code, args)
		return out
	end, 50)
	return out
end

---The nvim's message history. Only call it while the nvim isn't blocked.
---@param nvim jumanji.test.Nvim
---@return string
M.messages = function(nvim)
	-- Getting the history needs a non-fast request, which a prompt holds up.
	-- Dismiss the prompt first so the failure shows what caused it.
	for _ = 1, 100 do
		if not vim.rpcrequest(nvim.chan, "nvim_get_mode").blocking then break end
		vim.rpcrequest(nvim.chan, "nvim_input", "<Esc>")
		vim.wait(20)
	end
	return vim.rpcrequest(nvim.chan, "nvim_exec2", "messages", { output = true }).output
end

local before = function()
	state = { dir = vim.fs.joinpath(root, tostring(vim.uv.hrtime())), nvims = {} }
	vim.fn.mkdir(state.dir, "p")

	-- Keep the user's jj config out, so tests see jj's defaults
	local config = vim.fs.joinpath(state.dir, "jj-config.toml")
	vim.fn.writefile({ "[user]", 'name = "Test"', 'email = "test@example.com"' }, config)
	vim.env.JJ_CONFIG = config
end

local after = function()
	for _, nvim in ipairs(state.nvims) do
		vim.fn.jobstop(nvim.chan)
	end
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
