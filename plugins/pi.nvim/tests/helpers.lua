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
	if not x then error(msg or "expected a truthy value", 2) end
end

-- Sockets live under /tmp because macOS limits socket paths to 104 bytes
local root = "/tmp/pi-nvim-test-" .. vim.fn.getpid()
local plugin = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))

---@class pi.test.State
---@field dir string
---@field jobs integer[]
local state

---@return string
M.dir = function() return state.dir end

---Put a fake `pi` on the PATH of nvims started after this. It appends its
---arguments to `<dir>/pi-args` and keeps printing its terminal size.
---@return string bin
M.fake_pi = function()
	local bin = vim.fs.joinpath(state.dir, "bin")
	vim.fn.mkdir(bin, "p")
	vim.fn.writefile({
		"#!/bin/sh",
		'echo "$@" >> ' .. vim.fs.joinpath(state.dir, "pi-args"),
		"while :; do stty size; sleep 0.05; done",
	}, vim.fs.joinpath(bin, "pi"))
	vim.fn.setfperm(vim.fs.joinpath(bin, "pi"), "rwxr-xr-x")
	return bin
end

---Start a headless nvim with this plugin and a fake pi on its PATH, and wait for it.
---@param args? string[]
---@return string socket
M.spawn = function(args)
	local socket = vim.fs.joinpath(state.dir, "nvim-" .. #state.jobs .. ".sock")
	local cmd = { vim.v.progpath, "--clean", "--headless", "--listen", socket, "--cmd", "set rtp^=" .. plugin }
	local job = vim.fn.jobstart(vim.list_extend(cmd, args or {}), {
		cwd = state.dir,
		env = { PATH = vim.fs.joinpath(state.dir, "bin") .. ":" .. vim.env.PATH },
	})
	table.insert(state.jobs, job)
	M.truthy(vim.wait(3000, function() return pcall(M.remote, socket, "return true") end, 20), "nvim never started")
	return socket
end

---Run Lua in another nvim
---@param socket string
---@param code string
---@param args? any[]
M.remote = function(socket, code, args)
	local chan = vim.fn.sockconnect("pipe", socket, { rpc = true })
	local ok, out = pcall(vim.rpcrequest, chan, "nvim_exec_lua", code, args or {})
	vim.fn.chanclose(chan)
	if not ok then error(out, 2) end
	return out
end

---@param filter? string Only run tests whose name contains this
M.run = function(filter)
	local failed, ran = 0, 0
	for _, t in ipairs(tests) do
		if not filter or t.name:find(filter, 1, true) then
			ran = ran + 1
			state = { dir = vim.fs.joinpath(root, ("%d"):format(vim.uv.hrtime())), jobs = {} }
			vim.fn.mkdir(state.dir, "p")
			state.dir = vim.uv.fs_realpath(state.dir) --[[@as string]]

			local ok, err = xpcall(t.fn, debug.traceback)
			for _, job in ipairs(state.jobs) do
				vim.fn.jobstop(job)
			end
			vim.fn.jobwait(state.jobs, 3000)

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
