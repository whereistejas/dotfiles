local h = require("helpers")
local servery = require("servery")

local sockets = function(sessions)
	return vim.tbl_map(function(s) return s.server and s.server.socket or s.cwd end, sessions)
end

h.test("list_sessions puts the current session first, then running ones, then dirs by path", function()
	local b, a = h.dir("bbb"), h.dir("aaa")
	h.setup({ dirs = { b, a }, servers = function() return { vim.v.servername } end })
	local other = h.spawn(h.dir("other"))

	local got = sockets(servery.list_sessions())

	h.eq({ vim.v.servername, other, a, b }, got)
end)

h.test("list_sessions finds sessions started by servery even if servers() misses them", function()
	local other = h.spawn(h.dir("other"))
	h.eq({ other }, sockets(servery.list_sessions("active")))
end)

h.test("list_sessions lists each running session once", function()
	local other = h.spawn(h.dir("other"))
	h.setup({ servers = function() return { other, other, vim.v.servername, vim.v.servername } end })

	h.eq({ vim.v.servername, other }, sockets(servery.list_sessions("active")))
end)

h.test("list_sessions filters by status", function()
	local dir = h.dir("idle")
	h.setup({ dirs = { dir } })
	local other = h.spawn(h.dir("other"))

	h.eq({ other }, sockets(servery.list_sessions("active")))
	h.eq({ dir }, sockets(servery.list_sessions("inactive")))
end)

h.test("running sessions report their cwd and pid", function()
	local dir = h.dir("other")
	local other = h.spawn(dir)

	local session = servery.list_sessions("active")[1]

	h.eq(dir, session.cwd)
	h.eq(h.remote(other, "return vim.fn.getpid()"), session.server.pid)
	h.eq("other", session:display_name())
	h.eq("Active", session:status())
end)
