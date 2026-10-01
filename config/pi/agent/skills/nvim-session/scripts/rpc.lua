local async = vim.async

vim.fn.serverstop(vim.v.servername)

local USAGE = [[
usage:
  nvim --clean -l rpc.lua [--server SOCK] [--timeout SECS] [ARGS_JSON] < chunk.lua
  nvim --clean -l rpc.lua [--timeout SECS] --sessions

Runs the Lua chunk on stdin inside the session at SOCK (default: $NVIM) and
prints its return value as JSON. ARGS_JSON is an array whose elements become
the chunk's `...`. --timeout (default 10) bounds the wait for each session.

--sessions lists every running session (servery and plain nvim) as JSON.
Exit codes: 0 ok, 1 usage or Lua error, 2 timeout.]]

local function fail(msg, code)
	io.stderr:write("rpc.lua: ", msg, "\n")
	os.exit(code or 1)
end

local function usage(msg)
	fail(msg .. "\n\n" .. USAGE)
end

local NAME = "pi-rpc-" .. vim.fn.getpid()

-- Runs in the session. Finds this client's channel by the name it registered,
-- runs the chunk, and notifies the result back instead of answering a request,
-- so the client never blocks on the session.
local REMOTE = [[
local name, id, code, args = ...
local chan
for _, c in ipairs(vim.api.nvim_list_chans()) do
	if c.client and c.client.name == name then
		chan = c.id
		break
	end
end
if not chan then
	return
end
local ok, res = pcall(function()
	local f, err = load(code, "=chunk")
	if not f then
		error(err, 0)
	end
	return f(unpack(args, 1, #args))
end)
local function reply(...)
	return pcall(vim.rpcnotify, chan, "nvim_exec_lua", "_G.rpc_reply(...)", { id, ... })
end
if not reply(ok, res) then
	reply(false, "chunk returned a value that cannot be sent over RPC: " .. vim.inspect(res))
end
]]

local pending, next_id = {}, 0

function _G.rpc_reply(id, ok, res)
	local done = pending[id]
	pending[id] = nil
	if done then
		done(ok, res)
	end
end

local function connect(sock)
	local ok, chan = pcall(vim.fn.sockconnect, "pipe", sock, { rpc = true })
	if not ok or chan == 0 then
		return nil, ok and "connection failed" or chan
	end
	vim.rpcnotify(chan, "nvim_set_client_info", NAME, {}, "remote", {}, {})
	return chan
end

---@async
local function call(chan, chunk, args)
	next_id = next_id + 1
	local id = next_id
	local ok, res = async.await(function(done)
		pending[id] = done
		vim.rpcnotify(chan, "nvim_exec_lua", REMOTE, { NAME, id, chunk, args })
		return {
			close = function(_, cb)
				pending[id] = nil
				if cb then
					cb()
				end
			end,
		}
	end)
	if not ok then
		error("error in session: " .. tostring(res), 0)
	end
	return res
end

---@async
local function exec(chan, chunk, args, timeout)
	return async.timeout(timeout * 1000, async.run(call, chan, chunk, args))
end

local INFO = [[
return {
	cwd = vim.fn.getcwd(),
	original_cwd = vim.g.servery_original_cwd,
	name = vim.g.servery_name,
	uis = #vim.api.nvim_list_uis(),
	pid = vim.fn.getpid(),
}
]]

local function list_sockets()
	local socks, seen = {}, {}
	local function add(sock)
		if not seen[sock] then
			seen[sock] = true
			table.insert(socks, sock)
		end
	end
	local run = vim.fs.dirname(vim.fn.stdpath("run"))
	for path, type in vim.fs.dir(run, { depth = 2 }) do
		if type == "socket" and vim.fs.basename(path):match("^nvim%.%d+%.%d+$") then
			add(vim.fs.joinpath(run, path))
		end
	end
	local dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "servery.nvim")
	for name, type in vim.fs.dir(dir) do
		if type == "socket" then
			add(vim.fs.joinpath(dir, name))
		end
	end
	return socks
end

---@async
local function sessions(timeout)
	local probes = {}
	for _, sock in ipairs(list_sockets()) do
		local chan = connect(sock)
		if chan then
			table.insert(probes, { sock = sock, task = async.run(exec, chan, INFO, {}, timeout) })
		end
	end
	local out = {}
	for _, probe in ipairs(probes) do
		local ok, info = async.pawait(probe.task)
		table.insert(out, vim.tbl_extend("force", ok and info or { error = tostring(info) }, {
			socket = probe.sock,
			self = probe.sock == os.getenv("NVIM"),
		}))
	end
	return out
end

local function parse(argv)
	local opts = { timeout = 10, args = {} }
	local i = 1
	while i <= #argv do
		local a = argv[i]
		if a == "--sessions" then
			opts.sessions = true
		elseif a == "--server" or a == "--timeout" then
			local v = argv[i + 1] or usage(a .. " needs a value")
			if a == "--server" then
				opts.server = v
			else
				opts.timeout = tonumber(v) or usage("--timeout must be a number, got " .. v)
			end
			i = i + 1
		elseif vim.startswith(a, "--") then
			usage("unknown flag " .. a)
		else
			local ok, v = pcall(vim.json.decode, a)
			if not ok or type(v) ~= "table" or (next(v) ~= nil and not vim.islist(v)) then
				usage("ARGS_JSON must be a JSON array, got " .. a)
			end
			opts.args = v
		end
		i = i + 1
	end
	return opts
end

local opts = parse(_G.arg)
local main

if opts.sessions then
	main = function() return sessions(opts.timeout) end
else
	local sock = opts.server or os.getenv("NVIM")
	if not sock or sock == "" then
		usage("$NVIM is unset (not running inside a nvim terminal) and no --server given")
	end
	local chunk = io.read("a")
	if not chunk or chunk:match("^%s*$") then
		usage("no Lua chunk on stdin")
	end
	local chan, err = connect(sock)
	if not chan then
		fail(("cannot connect to %s: %s"):format(sock, err))
	end
	main = function() return exec(chan, chunk, opts.args, opts.timeout) end
end

local ok, res = async.run(main):pwait()
if not ok then
	if res == "timeout" then
		fail(("timed out after %ss; the session may be blocked on a prompt"):format(opts.timeout), 2)
	end
	fail(tostring(res))
end
io.stdout:write(vim.json.encode(res == nil and vim.NIL or res, { sort_keys = true }), "\n")
os.exit(0)
